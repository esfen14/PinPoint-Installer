#!/usr/bin/python3 -I
"""PinPoint Update Manager, Phase 3: validation and approval.

Scan the installed Nagios Core, Nagios Plugins and check_ncpa.py, compare them
with the bundled baseline manifest, record the scan in a root-only SQLite
database with a hash-chained audit log, and show the numbered console menu.

Manifests are read from the root-only folder /etc/pinpoint/updates/manifests/.
Manifests are not signed (decision of 28 October 2026): a file there is trusted
because only root can write it, and its SHA-256 is recorded the first time it
is seen, so a later edit is refused. The compatibility gate decides whether a
manifest may be installed on this host, and admins approve, defer or decline
it from the command line. An approval is bound to the manifest digest, this
host and the installed state, and is voided as soon as one of them changes.

Nothing here installs, downloads or changes Nagios. An approval creates a
transaction in the "approved" state; running it is a later phase. There is no
update catalog yet, so Reload reports the update status as UNKNOWN rather than
"up to date".
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import socket
import sqlite3
import subprocess
import sys
import time

NAGIOS = Path('/usr/local/nagios')
MANIFEST_DIR = Path('/etc/pinpoint/updates/manifests')
MANIFEST = MANIFEST_DIR / 'pp-mon-baseline-1.json'
REVOKED = 'revoked.json'
STATE_DIR = Path('/var/lib/pinpoint/updates')
APP_DIR = Path('/opt/pinpoint/Network-Diagnosis-System')
OS_RELEASE = Path('/etc/os-release')
LOG = Path('/var/log/pinpoint-update.log')
# Each audit row is also copied here, so deleting the database cannot erase history silently.
JOURNAL = ('logger', '-t', 'pinpoint-update', '--')
# Created by configure-monitoring-updates.sh on a fresh install only; the login
# hook opens the menu once while it exists. World-readable folder, unlike STATE_DIR.
MENU_PENDING = Path('/var/lib/pinpoint/update-menu-pending')
CATALOG_URL = None  # No signed catalog exists yet (plan section 6.1).
COMPONENTS = (('nagios-core', 'Nagios Core'), ('nagios-plugins', 'Nagios Plugins'), ('check-ncpa', 'check_ncpa'))
# Build recipes shipped in the updater code; a manifest can only name one (plan 6.1).
BUILD_PROFILES = {'nagios-core': 'core-source-v1', 'nagios-plugins': 'plugins-source-v1',
                  'check-ncpa': 'ncpa-client-v1'}
COMPAT_STATES = ('verified', 'conditional', 'untested', 'incompatible', 'deprecated')
INSTALLABLE = ('verified', 'conditional')
MIGRATION_CLASSES = ('binary-only', 'config-compatible', 'config-migration', 'major')
ADMINS, VIEWERS = 'pinpoint-update-admins', 'pinpoint-update-viewers'
ADMIN_COMMANDS = ('approve', 'defer', 'decline', 'cancel')
APPROVAL_DAYS = 14  # <PLACEHOLDER 14 days> in plan section 7.1
DEFAULT_DOWNTIME = 15  # minutes, when a manifest does not say
ID_PATTERN = r'[a-z0-9.-]{1,64}'
TXN_PATTERN = r'txn-[0-9]{14}-[0-9a-f]{6}'
RUN_TIMEOUT = 15

OK, INVALID_INPUT, NOT_AUTHORISED, BLOCKED, BUSY, INVALID_TRANSITION = 0, 2, 3, 4, 5, 6
CODE_NAMES = {OK: 'OK', INVALID_INPUT: 'INVALID_INPUT', NOT_AUTHORISED: 'NOT_AUTHORISED', BLOCKED: 'BLOCKED',
              BUSY: 'BUSY', INVALID_TRANSITION: 'INVALID_TRANSITION'}

ACTIVE = ('approved', 'preparing', 'staging', 'applying', 'health_check', 'rolling_back')
# Plan section 7.1. preparing -> failed is only used by reconcile, for a
# transaction that stopped before anything was touched.
TRANSITIONS = {
    'approved': ('preparing', 'cancelled', 'missed_window'),
    'preparing': ('blocked', 'staging', 'failed'),
    'staging': ('cancelled', 'failed', 'applying'),
    'applying': ('health_check', 'rolling_back'),
    'health_check': ('succeeded', 'rolling_back'),
    'rolling_back': ('rolled_back', 'recovery_failed'),
}
TXN_FIELDS = ('step', 'recovery_point_id', 'failure_code', 'recovery_status', 'started_at', 'finished_at',
              'downtime_seconds')

SCHEMA = """
CREATE TABLE IF NOT EXISTS inventory (
  scan_id TEXT NOT NULL, host_id TEXT NOT NULL, component TEXT NOT NULL,
  installed_version TEXT, managed INTEGER NOT NULL, artifact_sha256 TEXT,
  scanned_at TEXT NOT NULL, PRIMARY KEY (scan_id, component));
CREATE TABLE IF NOT EXISTS installed_state (
  host_id TEXT PRIMARY KEY, manifest_id TEXT NOT NULL, since TEXT NOT NULL, last_txn_id TEXT);
CREATE TABLE IF NOT EXISTS audit (
  seq INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, actor TEXT NOT NULL,
  event TEXT NOT NULL, txn_id TEXT, manifest_id TEXT, detail_json TEXT NOT NULL,
  prev_hash TEXT NOT NULL, hash TEXT NOT NULL);
-- Two writers that read the same last row would fork the chain; this refuses the second.
CREATE UNIQUE INDEX IF NOT EXISTS audit_chain ON audit(prev_hash);
CREATE TABLE IF NOT EXISTS txn (
  txn_id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK (kind IN ('update', 'drill')),
  host_id TEXT NOT NULL, source_manifest_id TEXT NOT NULL, target_manifest_id TEXT NOT NULL,
  approval_id TEXT, state TEXT NOT NULL, step TEXT, recovery_point_id TEXT, failure_code TEXT,
  recovery_status TEXT, created_at TEXT NOT NULL, started_at TEXT, finished_at TEXT,
  downtime_seconds INTEGER);
CREATE UNIQUE INDEX IF NOT EXISTS one_active_txn ON txn(host_id)
  WHERE state NOT IN ('succeeded', 'rolled_back', 'failed', 'recovery_failed', 'cancelled',
                      'missed_window', 'blocked');
CREATE TABLE IF NOT EXISTS recovery_point (
  rp_id TEXT PRIMARY KEY, txn_id TEXT NOT NULL, kind TEXT NOT NULL, location TEXT NOT NULL,
  file_manifest_sha256 TEXT NOT NULL, size_bytes INTEGER NOT NULL, created_at TEXT NOT NULL,
  verified_at TEXT, restore_tested TEXT, retain_until TEXT);
CREATE TABLE IF NOT EXISTS manifest (
  manifest_id TEXT PRIMARY KEY, schema_version INTEGER NOT NULL, sha256 TEXT NOT NULL UNIQUE,
  compat_state TEXT NOT NULL CHECK (compat_state IN
                ('verified', 'conditional', 'untested', 'incompatible', 'deprecated')),
  source TEXT NOT NULL CHECK (source IN ('bundled', 'local', 'catalog')),
  body_json TEXT NOT NULL, first_seen_at TEXT NOT NULL, revoked_at TEXT);
CREATE TABLE IF NOT EXISTS approval (
  approval_id TEXT PRIMARY KEY, manifest_id TEXT NOT NULL REFERENCES manifest,
  manifest_sha256 TEXT NOT NULL, host_id TEXT NOT NULL, source_manifest_id TEXT NOT NULL,
  approver TEXT NOT NULL, decision TEXT NOT NULL CHECK (decision IN ('approve', 'defer', 'decline')),
  reason TEXT, window_start TEXT, window_end TEXT, review_date TEXT, created_at TEXT NOT NULL,
  expires_at TEXT,
  status TEXT NOT NULL CHECK (status IN ('active', 'used', 'expired', 'revoked', 'superseded')));
"""


class CommandError(Exception):
    """A refused command: an exit code from plan section 8.5 and a message for the admin."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


class InvalidTransition(Exception):
    pass


def utc(moment):
    return moment.astimezone(datetime.timezone.utc).replace(microsecond=0).isoformat()


def now():
    return utc(datetime.datetime.now(datetime.timezone.utc))


def later(days=0, minutes=0):
    return utc(datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=days, minutes=minutes))


def make_id(prefix):
    return '%s-%s-%s' % (prefix, time.strftime('%Y%m%d%H%M%S', time.gmtime()), os.urandom(3).hex())


def actor():
    """The person behind sudo, or root for a direct root login."""
    return os.environ.get('SUDO_USER') or 'root'


def user_groups(user):
    import grp  # Linux only; imported here so the unit tests also run on other systems
    import pwd
    try:
        gids = os.getgrouplist(user, pwd.getpwnam(user).pw_gid)
    except KeyError:
        return set()
    names = set()
    for gid in gids:
        try:
            names.add(grp.getgrgid(gid).gr_name)
        except KeyError:
            pass
    return names


def role():
    """'admin', 'viewer' or None, from the sudo caller's groups (plan 8.3). Direct root is an admin."""
    user = os.environ.get('SUDO_USER')
    if not user or user == 'root':
        return 'admin'
    groups = user_groups(user)
    return 'admin' if ADMINS in groups else 'viewer' if VIEWERS in groups else None


def run(args):
    """Run a fixed command and return its output, or '' if it cannot run."""
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=RUN_TIMEOUT, check=False)
    except (OSError, subprocess.SubprocessError):
        return ''
    return done.stdout + done.stderr


def copy_out(line):
    """Copy an audit row to the log file and the journal. Neither may stop the program."""
    try:
        with open(LOG, 'a', encoding='utf-8') as f:
            f.write(line + '\n')
    except OSError:
        pass
    if JOURNAL:
        try:
            subprocess.run([*JOURNAL, line], capture_output=True, timeout=RUN_TIMEOUT, check=False)
        except (OSError, subprocess.SubprocessError):
            pass


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            digest.update(chunk)
    return digest.hexdigest()


##################################################
# Manifests
##################################################

def require(condition, problem):
    if not condition:
        raise ValueError(problem)


def text_field(value, pattern, name):
    require(isinstance(value, str) and re.fullmatch(pattern, value), 'invalid %s' % name)
    return value


def check_manifest(manifest):
    """Raise ValueError naming the first problem. A manifest is data and never names a command."""
    require(isinstance(manifest, dict), 'not a JSON object')
    require(manifest.get('schema_version') == 1, 'unsupported schema_version')
    text_field(manifest.get('manifest_id'), ID_PATTERN, 'manifest_id')
    target = manifest.get('platform')
    require(isinstance(target, dict), 'missing platform')
    for key in ('os', 'version', 'arch'):
        text_field(target.get(key), r'[A-Za-z0-9._-]{1,32}', 'platform.' + key)
    components = manifest.get('components')
    require(isinstance(components, dict) and set(components) == set(BUILD_PROFILES),
            'components must be exactly %s' % ', '.join(sorted(BUILD_PROFILES)))
    for key, profile in BUILD_PROFILES.items():
        part = components[key]
        require(isinstance(part, dict) and isinstance(part.get('artifact'), dict), 'invalid component ' + key)
        text_field(part.get('version'), r'[0-9A-Za-z.+-]{1,32}', key + ' version')
        text_field(part['artifact'].get('url'), r'https://[^\s]{1,500}', key + ' artifact url')
        text_field(part['artifact'].get('sha256'), r'[0-9a-f]{64}', key + ' artifact sha256')
        require(part.get('build_profile') == profile, '%s build_profile must be %s' % (key, profile))
    upgrade_from = manifest.get('upgrade_from')
    require(isinstance(upgrade_from, list), 'upgrade_from must be a list')
    for source in upgrade_from:
        text_field(source, ID_PATTERN, 'upgrade_from entry')
    require(manifest.get('migration_class') in MIGRATION_CLASSES, 'invalid migration_class')
    compat = manifest.get('compatibility')
    require(isinstance(compat, dict) and compat.get('state') in COMPAT_STATES, 'invalid compatibility.state')
    for key in ('evidence_ids', 'known_limitations'):
        values = compat.get(key, [])
        require(isinstance(values, list) and all(isinstance(v, str) for v in values), 'invalid compatibility.' + key)
    downtime = manifest.get('expected_downtime_minutes', DEFAULT_DOWNTIME)
    require(isinstance(downtime, int) and 1 <= downtime <= 240, 'invalid expected_downtime_minutes')
    return manifest


def load_manifest(path=None):
    with open(path or MANIFEST, encoding='utf-8') as f:
        return check_manifest(json.load(f))


def trusted_file(path):
    """Owned by root and writable by nobody else: what makes a manifest trusted while none are signed."""
    st = os.stat(path)
    return st.st_uid == 0 and not st.st_mode & 0o022


def register_manifests(store):
    """Record every manifest in MANIFEST_DIR and apply revoked.json.

    Returns {file name: problem} for the files that were refused. A manifest
    whose bytes changed after it was recorded is refused: a change needs a new
    manifest_id (plan 6.1).
    """
    problems = {}
    try:
        if not trusted_file(MANIFEST_DIR):
            return {MANIFEST_DIR.name: 'the folder is not root-only; no manifest is trusted'}
        paths = sorted(MANIFEST_DIR.glob('*.json'))
    except OSError as error:
        return {MANIFEST_DIR.name: 'cannot be read (%s)' % type(error).__name__}
    for path in paths:
        if path.name == REVOKED:
            continue
        try:
            require(trusted_file(path), 'not owned by root, or writable by others')
            raw = path.read_bytes()
            body = check_manifest(json.loads(raw))
            require(path.name == body['manifest_id'] + '.json', 'file name does not match manifest_id')
        except (OSError, ValueError) as error:
            problems[path.name] = str(error) or type(error).__name__
            continue
        digest, mid = hashlib.sha256(raw).hexdigest(), body['manifest_id']
        row = store.db.execute('SELECT sha256 FROM manifest WHERE manifest_id = ?', (mid,)).fetchone()
        if row is None:
            with store.db:
                store.db.execute('INSERT INTO manifest (manifest_id, schema_version, sha256, compat_state, source, '
                                 'body_json, first_seen_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
                                 (mid, 1, digest, body['compatibility']['state'],
                                  'bundled' if path.name == MANIFEST.name else 'local', raw.decode(), now()))
                store.audit('manifest.registered', {'sha256': digest, 'compat_state': body['compatibility']['state']},
                            mid)
        elif row[0] != digest:
            problems[path.name] = 'changed after it was recorded; a changed manifest needs a new manifest_id'
            detail = {'recorded_sha256': row[0], 'file_sha256': digest}
            if not store.db.execute('SELECT 1 FROM audit WHERE event = ? AND manifest_id = ? AND detail_json = ?',
                                    ('manifest.changed', mid, canonical(detail))).fetchone():
                with store.db:
                    store.audit('manifest.changed', detail, mid)
    problems.update(apply_revocations(store))
    return problems


def apply_revocations(store):
    """revoked.json: {"schema_version": 1, "manifest_ids": [...]}. A revoked manifest becomes deprecated."""
    path = MANIFEST_DIR / REVOKED
    if not path.exists():
        return {}
    try:
        require(trusted_file(path), 'not owned by root, or writable by others')
        body = json.loads(path.read_bytes())
        require(isinstance(body, dict) and body.get('schema_version') == 1, 'unsupported schema_version')
        ids = body.get('manifest_ids')
        require(isinstance(ids, list), 'manifest_ids must be a list')
        for mid in ids:
            text_field(mid, ID_PATTERN, 'manifest id')
    except (OSError, ValueError) as error:
        return {REVOKED: str(error) or type(error).__name__}
    for mid in ids:
        with store.db:
            if store.db.execute("UPDATE manifest SET compat_state = 'deprecated', revoked_at = ? "
                                'WHERE manifest_id = ? AND revoked_at IS NULL', (now(), mid)).rowcount:
                store.audit('manifest.revoked', {}, mid)
    return {}


def parse_core_version(text):
    match = re.search(r'Nagios Core ([0-9][0-9A-Za-z.+-]*)', text)
    return match[1] if match else None


def parse_plugins_version(text):
    match = re.search(r'nagios-plugins ([0-9][0-9A-Za-z.+-]*)', text)
    return match[1] if match else None


def parse_ncpa_version(text):
    match = re.search(r'check_ncpa\.py, Version ([0-9][0-9A-Za-z.+-]*)', text)
    return match[1] if match else None


def host_id():
    try:
        return Path('/etc/machine-id').read_text().strip() or socket.gethostname()
    except OSError:
        return socket.gethostname()


def os_profile():
    fields = {}
    try:
        for line in OS_RELEASE.read_text().splitlines():
            key, _, value = line.partition('=')
            fields[key] = value.strip('"')
    except OSError:
        pass
    return {'os': fields.get('ID', 'unknown'), 'version': fields.get('VERSION_ID', 'unknown'),
            'arch': platform.machine() or 'unknown'}


def app_commit():
    """Read the PinPoint checkout's HEAD without running git as root in another user's repo."""
    git = APP_DIR / '.git'
    try:
        head = (git / 'HEAD').read_text().strip()
        if not head.startswith('ref: '):
            return head[:40] or None
        ref = head[5:]
        if (git / ref).is_file():
            return (git / ref).read_text().strip()[:40]
        for line in (git / 'packed-refs').read_text().splitlines():
            if line.endswith(' ' + ref):
                return line.split(' ', 1)[0][:40]
    except OSError:
        pass
    return None


def scan():
    """Return {component: {'version', 'sha256'}} for the managed components."""
    core = NAGIOS / 'bin/nagios'
    ping = NAGIOS / 'libexec/check_ping'
    ncpa = NAGIOS / 'libexec/check_ncpa.py'
    found = {
        'nagios-core': {'version': parse_core_version(run([str(core), '-V'])) if core.is_file() else None,
                        'sha256': sha256_file(core) if core.is_file() else None},
        'nagios-plugins': {'version': parse_plugins_version(run([str(ping), '-V'])) if ping.is_file() else None,
                           'sha256': None},
        'check-ncpa': {'version': parse_ncpa_version(run([str(ncpa), '--version'])) if ncpa.is_file() else None,
                       'sha256': sha256_file(ncpa) if ncpa.is_file() else None},
    }
    return found


def compare(found, manifest):
    """Status of each component against the manifest: up to date, differs, not installed or unknown."""
    rows = []
    for key, label in COMPONENTS:
        wanted = manifest['components'][key]['version']
        have = found.get(key, {}).get('version')
        if have is None:
            exists = {'nagios-core': NAGIOS / 'bin/nagios', 'nagios-plugins': NAGIOS / 'libexec/check_ping',
                      'check-ncpa': NAGIOS / 'libexec/check_ncpa.py'}[key].exists()
            status = 'UNKNOWN' if exists else 'NOT INSTALLED'
        else:
            status = 'baseline' if have == wanted else 'DIFFERS'
        rows.append({'component': key, 'label': label, 'installed': have, 'baseline': wanted, 'status': status})
    return rows


def canonical(detail):
    return json.dumps(detail, sort_keys=True, separators=(',', ':'))


class Store:
    """Root-only SQLite state: inventory, manifests, approvals, transactions and the audit chain."""

    def __init__(self, state_dir=None):
        self.dir = Path(state_dir or STATE_DIR)
        self.dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.dir, 0o700)
        self.path = self.dir / 'updates.db'
        self.db = sqlite3.connect(str(self.path), timeout=10)
        os.chmod(self.path, 0o600)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.executescript(SCHEMA)

    def close(self):
        self.db.close()

    def audit(self, event, detail, manifest_id=None, txn_id=None, who=None):
        row = self.db.execute('SELECT hash FROM audit ORDER BY seq DESC LIMIT 1').fetchone()
        prev = row[0] if row else '0' * 64
        at, who = now(), who or actor()
        body = canonical(detail)
        chained = json.dumps([prev, at, who, event, txn_id, manifest_id, body], separators=(',', ':'))
        digest = hashlib.sha256(chained.encode()).hexdigest()
        self.db.execute('INSERT INTO audit (at, actor, event, txn_id, manifest_id, detail_json, prev_hash, hash) '
                        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)', (at, who, event, txn_id, manifest_id, body, prev, digest))
        copy_out('%s %s %s txn=%s manifest=%s %s hash=%s'
                 % (at, who, event, txn_id or '-', manifest_id or '-', body, digest))

    def verify_audit(self):
        """Return the seq of the first broken or missing row, or None if the chain is intact.

        Rows are numbered without gaps, so removing the newest rows is found as
        soon as another row is written; until then the log and journal copies
        are the record.
        """
        prev, expected = '0' * 64, 1
        for seq, at, who, event, txn, mid, body, prev_hash, digest in self.db.execute(
                'SELECT seq, at, actor, event, txn_id, manifest_id, detail_json, prev_hash, hash FROM audit ORDER BY seq'):
            chained = json.dumps([prev, at, who, event, txn, mid, body], separators=(',', ':'))
            if seq != expected or prev_hash != prev or hashlib.sha256(chained.encode()).hexdigest() != digest:
                return min(seq, expected)
            prev, expected = digest, seq + 1
        return None

    def record_scan(self, found, rows, manifest):
        scan_id, at, host = now() + '-' + os.urandom(4).hex(), now(), host_id()
        with self.db:
            for key, _ in COMPONENTS:
                self.db.execute('INSERT INTO inventory VALUES (?, ?, ?, ?, 1, ?, ?)',
                                (scan_id, host, key, found[key]['version'], found[key]['sha256'], at))
            if all(r['status'] == 'baseline' for r in rows) and not self.installed_manifest():
                self.db.execute('INSERT INTO installed_state VALUES (?, ?, ?, NULL)', (host, manifest['manifest_id'], at))
                self.audit('installed_state.recorded', {'source': 'installer-baseline'}, manifest['manifest_id'])
            self.audit('inventory.scanned', {'scan_id': scan_id, 'status': {r['component']: r['status'] for r in rows}},
                       manifest['manifest_id'])
        return scan_id

    def installed_manifest(self):
        row = self.db.execute('SELECT manifest_id FROM installed_state WHERE host_id = ?', (host_id(),)).fetchone()
        return row[0] if row else None

    def manifest(self, manifest_id):
        """The recorded manifest as a dict with its parsed body, or None."""
        self.db.row_factory = sqlite3.Row
        try:
            row = self.db.execute('SELECT * FROM manifest WHERE manifest_id = ?', (manifest_id,)).fetchone()
        finally:
            self.db.row_factory = None
        if row is None:
            return None
        found = dict(row)
        found['body'] = json.loads(found.pop('body_json'))
        return found

    def rows(self, sql, args=()):
        """Query results as a list of dicts."""
        self.db.row_factory = sqlite3.Row
        try:
            return [dict(row) for row in self.db.execute(sql, args)]
        finally:
            self.db.row_factory = None


def active_txn(store):
    marks = ','.join('?' * len(ACTIVE))
    return store.db.execute('SELECT txn_id, state, step, recovery_point_id FROM txn WHERE host_id = ? '
                            'AND state IN (%s)' % marks, (host_id(), *ACTIVE)).fetchone()


def transition(store, txn_id, to, who='executor', **fields):
    """The only way a transaction changes state: checked against plan 7.1, audited in the same commit."""
    unknown = set(fields) - set(TXN_FIELDS)
    if unknown:
        raise ValueError('unknown txn fields: %s' % ', '.join(sorted(unknown)))
    with store.db:
        row = store.db.execute('SELECT state FROM txn WHERE txn_id = ?', (txn_id,)).fetchone()
        if row is None or to not in TRANSITIONS.get(row[0], ()):
            raise InvalidTransition('%s: %s -> %s' % (txn_id, row[0] if row else 'missing', to))
        if to not in ACTIVE:
            fields.setdefault('finished_at', now())
        values = {'state': to, **fields}
        store.db.execute('UPDATE txn SET %s WHERE txn_id = ?' % ', '.join('%s = ?' % k for k in values),
                         (*values.values(), txn_id))
        store.audit('txn.' + to, {'from': row[0], **fields}, txn_id=txn_id, who=who)


def inventory(store, manifest):
    found = scan()
    rows = compare(found, manifest)
    store.record_scan(found, rows, manifest)
    return rows


##################################################
# Compatibility gate and approvals
##################################################

def gate(store, manifest_id, found):
    """Reasons this host may not install MANIFEST_ID now; an empty list means it may (plan 6.1, 10.2)."""
    record = store.manifest(manifest_id)
    if record is None:
        return ['%s is not a recorded manifest.' % manifest_id]
    body, reasons = record['body'], []
    if record['revoked_at']:
        reasons.append('%s was revoked on %s.' % (manifest_id, record['revoked_at']))
    elif record['compat_state'] not in INSTALLABLE:
        reasons.append('Compatibility is %s; only verified or conditional update sets can be installed.'
                       % record['compat_state'])
    if body['migration_class'] == 'major':
        reasons.append('A major change cannot be installed through the Update Manager.')
    here = os_profile()
    wanted = {key: body['platform'][key] for key in ('os', 'version', 'arch')}
    if wanted != here:
        reasons.append('Built for %(os)s %(version)s %(arch)s; ' % wanted
                       + 'this host is %(os)s %(version)s %(arch)s.' % here)
    installed = store.installed_manifest()
    if installed is None:
        reasons.append('The installed state is not recorded: the installed versions match no known manifest.')
    elif installed == manifest_id:
        reasons.append('%s is already installed.' % manifest_id)
    elif installed not in body['upgrade_from']:
        reasons.append('%s cannot be installed over %s (it upgrades from: %s).'
                       % (manifest_id, installed, ', '.join(body['upgrade_from']) or 'nothing'))
    else:
        current = store.manifest(installed)
        if current is None:
            reasons.append('The installed manifest %s is not recorded.' % installed)
        else:
            drift = [r['label'] for r in compare(found, current['body']) if r['status'] != 'baseline']
            if drift:
                reasons.append('Nagios was changed outside the Update Manager (%s differs from %s). '
                               'Investigate before approving.' % (', '.join(drift), installed))
    return reasons


def decisions(store, manifest_id=None, decision=None, status='active'):
    sql, args = 'SELECT * FROM approval WHERE host_id = ? AND status = ?', [host_id(), status]
    if manifest_id:
        sql, args = sql + ' AND manifest_id = ?', args + [manifest_id]
    if decision:
        sql, args = sql + ' AND decision = ?', args + [decision]
    return store.rows(sql + ' ORDER BY created_at, rowid', args)


def approval_txn(store, approval_id):
    """(txn_id, state) of the transaction an approval created, or (None, None)."""
    row = store.db.execute('SELECT txn_id, state FROM txn WHERE approval_id = ?', (approval_id,)).fetchone()
    return row or (None, None)


def approved_txn(store, approval_id):
    txn_id, state = approval_txn(store, approval_id)
    return txn_id if state == 'approved' else None


def end_approval(store, approval, status, why, txn_state='cancelled', who=None):
    """Void an approval and stop its transaction if it has not started."""
    txn_id = approved_txn(store, approval['approval_id'])
    if txn_id:
        transition(store, txn_id, txn_state, who or actor(), failure_code='APPROVAL_' + status.upper(),
                   recovery_status=why[:500])
    with store.db:
        store.db.execute('UPDATE approval SET status = ? WHERE approval_id = ?', (status, approval['approval_id']))
        store.audit('approval.' + status, {'approval_id': approval['approval_id'], 'reason': why,
                                           **({} if who else root_warning())},
                    approval['manifest_id'], txn_id, who)


def invalidate(store, found):
    """Void approvals that no longer hold (plan 7.1), and end deferrals whose review date has come."""
    stamp, today, installed = now(), datetime.date.today().isoformat(), store.installed_manifest()
    # Every host's approvals, so one made before the machine ID changed is voided too.
    for approval in store.rows("SELECT * FROM approval WHERE status = 'active' AND decision = 'approve'"):
        if approval_txn(store, approval['approval_id'])[1] in ACTIVE[1:]:
            continue  # already running: the executor re-checks it and owns the outcome
        why, status, txn_state = None, 'expired', 'cancelled'
        if approval['host_id'] != host_id():
            why = 'approved on another host (%s)' % approval['host_id']
        elif approval['window_end'] and approval['window_end'] <= stamp:
            why, txn_state = 'the maintenance window passed', 'missed_window'
        elif approval['expires_at'] <= stamp:
            why = 'the approval expired'
        elif installed != approval['source_manifest_id']:
            why = 'the installed state changed from %s' % approval['source_manifest_id']
        else:
            record = store.manifest(approval['manifest_id'])
            reasons = gate(store, approval['manifest_id'], found)
            if record and record['sha256'] != approval['manifest_sha256']:
                reasons.insert(0, 'the manifest digest changed')
            if reasons:
                why, status = reasons[0], 'revoked'
        if why:
            end_approval(store, approval, status, why, txn_state, who='system')
    for deferral in decisions(store, decision='defer'):
        if deferral['review_date'] <= today:
            with store.db:
                store.db.execute("UPDATE approval SET status = 'expired' WHERE approval_id = ?",
                                 (deferral['approval_id'],))
                store.audit('approval.review_due', {'approval_id': deferral['approval_id']},
                            deferral['manifest_id'], who='system')


def refresh(store, manifest):
    """Record manifests and a fresh inventory, then void what no longer holds. Returns refused files."""
    problems = register_manifests(store)
    found = scan()
    store.record_scan(found, compare(found, manifest), manifest)
    invalidate(store, found)
    return found, problems


def approve(store, manifest_id, found, at=None, window_minutes=None, accept_limitations=False):
    """Approve MANIFEST_ID for this host and create its transaction (AwaitingApproval -> Approved)."""
    existing = decisions(store, manifest_id, 'approve')
    if existing:
        return existing[0], approval_txn(store, existing[0]['approval_id'])[0], False
    reasons = gate(store, manifest_id, found)
    if reasons:
        raise CommandError(BLOCKED, ' '.join(reasons))
    record = store.manifest(manifest_id)
    body = record['body']
    limitations = body['compatibility'].get('known_limitations', [])
    if record['compat_state'] == 'conditional' and not accept_limitations:
        raise CommandError(INVALID_INPUT, '%s is conditional. Known limitations: %s Add --accept-limitations '
                           'to approve it anyway.' % (manifest_id, ' '.join(limitations) or 'none listed.'))
    expires = later(days=APPROVAL_DAYS)
    window_start = window_end = None
    if at:
        downtime = body.get('expected_downtime_minutes', DEFAULT_DOWNTIME)
        minutes = window_minutes or max(60, 2 * downtime)
        if minutes < 2 * downtime:
            raise CommandError(INVALID_INPUT, 'The window must allow the update and a rollback: at least %d minutes.'
                               % (2 * downtime))
        start = datetime.datetime.fromisoformat(at)
        window_start, window_end = at, utc(start + datetime.timedelta(minutes=minutes))
        if window_start <= now():
            raise CommandError(INVALID_INPUT, 'The window must start in the future.')
        if window_end > expires:
            raise CommandError(INVALID_INPUT, 'The window must end before the approval expires (%s).' % expires)
    elif window_minutes:
        raise CommandError(INVALID_INPUT, '--window-minutes needs --at.')
    others = decisions(store, decision='approve')
    busy = active_txn(store)
    if busy and busy[0] not in [approved_txn(store, other['approval_id']) for other in others]:
        raise CommandError(BUSY, 'Transaction %s is %s; nothing was approved.' % (busy[0], busy[1]))
    for other in others:
        end_approval(store, other, 'superseded', 'superseded by an approval of %s' % manifest_id)
    approval_id, txn_id, stamp = make_id('apr'), make_id('txn'), now()
    source = store.installed_manifest()
    approval = {'approval_id': approval_id, 'manifest_id': manifest_id, 'manifest_sha256': record['sha256'],
                'host_id': host_id(), 'source_manifest_id': source, 'approver': actor(), 'decision': 'approve',
                'reason': None, 'window_start': window_start, 'window_end': window_end, 'review_date': None,
                'created_at': stamp, 'expires_at': expires, 'status': 'active'}
    try:
        with store.db:
            store.db.execute('INSERT INTO approval (%s) VALUES (%s)' % (', '.join(approval), ', '.join('?' * len(approval))),
                             tuple(approval.values()))
            store.db.execute('INSERT INTO txn (txn_id, kind, host_id, source_manifest_id, target_manifest_id, '
                             'approval_id, state, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                             (txn_id, 'update', host_id(), source, manifest_id, approval_id, 'approved', stamp))
            store.audit('approval.created', {'approval_id': approval_id, 'manifest_sha256': record['sha256'],
                                             'source_manifest_id': source, 'window_start': window_start,
                                             'window_end': window_end, 'expires_at': expires,
                                             'conditional': record['compat_state'] == 'conditional',
                                             **root_warning()}, manifest_id, txn_id)
    except sqlite3.IntegrityError:
        raise CommandError(BUSY, 'Another transaction started at the same time; nothing was approved.')
    return approval, txn_id, True


def refuse(store, manifest_id, decision, reason, review_date=None):
    """Record a deferral or a decline. Monitoring keeps running on the installed version (plan 8.2)."""
    if store.manifest(manifest_id) is None:
        raise CommandError(INVALID_INPUT, '%s is not a recorded manifest.' % manifest_id)
    approved = decisions(store, manifest_id, 'approve')
    if approved:
        raise CommandError(INVALID_TRANSITION, '%s is approved (transaction %s). Cancel it first.'
                           % (manifest_id, approval_txn(store, approved[0]['approval_id'])[0]))
    for earlier in decisions(store, manifest_id):
        if (earlier['decision'], earlier['reason'], earlier['review_date']) == (decision, reason, review_date):
            return earlier, False
    approval_id, stamp = make_id('apr'), now()
    approval = {'approval_id': approval_id, 'manifest_id': manifest_id,
                'manifest_sha256': store.manifest(manifest_id)['sha256'], 'host_id': host_id(),
                'source_manifest_id': store.installed_manifest() or '-', 'approver': actor(), 'decision': decision,
                'reason': reason, 'review_date': review_date, 'created_at': stamp, 'status': 'active'}
    with store.db:
        for earlier in decisions(store, manifest_id):
            store.db.execute("UPDATE approval SET status = 'superseded' WHERE approval_id = ?",
                             (earlier['approval_id'],))
        store.db.execute('INSERT INTO approval (%s) VALUES (%s)' % (', '.join(approval), ', '.join('?' * len(approval))),
                         tuple(approval.values()))
        store.audit({'defer': 'approval.deferred', 'decline': 'approval.declined'}[decision],
                    {'approval_id': approval_id, 'reason': reason, 'review_date': review_date, **root_warning()},
                    manifest_id)
    return approval, True


def cancel(store, txn_id):
    """Approved or Staging -> Cancelled. Applying and later cannot be cancelled (plan 7.1)."""
    row = store.db.execute('SELECT kind, state, approval_id, target_manifest_id FROM txn WHERE txn_id = ? '
                           'AND host_id = ?', (txn_id, host_id())).fetchone()
    if row is None or row[0] != 'update':
        raise CommandError(INVALID_INPUT, 'No update transaction %s on this host.' % txn_id)
    kind, state, approval_id, manifest_id = row
    if state == 'cancelled':
        return False
    if state not in ('approved', 'staging'):
        raise CommandError(INVALID_TRANSITION, 'Transaction %s is %s and can no longer be cancelled.' % (txn_id, state))
    why = 'cancelled by %s' % actor()
    if state == 'staging':
        transition(store, txn_id, 'cancelled', actor(), failure_code='CANCELLED', recovery_status=why)
    approval = store.rows("SELECT * FROM approval WHERE approval_id = ? AND status = 'active'", (approval_id,))
    if approval:
        end_approval(store, approval[0], 'revoked', why)  # also cancels the transaction while it is approved
    return True


def root_warning():
    """A direct root login is allowed for emergencies and recorded with a warning (plan 8.3)."""
    return {} if os.environ.get('SUDO_USER') else {'warning': 'direct root login, no SUDO_USER'}


def manifest_summary(store, record, found):
    body = record['body']
    latest = store.rows('SELECT decision, status, reason, review_date, approver, created_at FROM approval '
                        'WHERE manifest_id = ? AND host_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1',
                        (record['manifest_id'], host_id()))
    reasons = gate(store, record['manifest_id'], found)
    return {'manifest_id': record['manifest_id'], 'sha256': record['sha256'], 'source': record['source'],
            'compat_state': record['compat_state'], 'revoked_at': record['revoked_at'],
            'versions': {key: body['components'][key]['version'] for key, _ in COMPONENTS},
            'upgrade_from': body['upgrade_from'], 'migration_class': body['migration_class'],
            'installable': not reasons, 'blocked_by': reasons, 'latest_decision': latest[0] if latest else None}


##################################################
# Console output
##################################################

def catalog_status():
    """There is no catalog yet: the result is always UNKNOWN, never 'up to date'."""
    if CATALOG_URL is None:
        return 'UNKNOWN (no update catalog is configured yet)'
    return 'UNKNOWN'


def render(rows, manifest, store, update_status):
    width = 64
    profile = os_profile()
    lines = ['=' * width,
             '  PinPoint Update Manager'.ljust(width - 30) + ('host: ' + socket.gethostname())[:30].rjust(30),
             '  %s %s %s' % (profile['os'].capitalize(), profile['version'], profile['arch']),
             '-' * width,
             '  %-18s %-13s %-13s %s' % ('Component', 'Installed', 'Baseline', 'Status')]
    for r in rows:
        lines.append('  %-18s %-13s %-13s %s' % (r['label'], r['installed'] or '-', r['baseline'], r['status']))
    installed = store.installed_manifest()
    lines += ['-' * width,
              '  Baseline manifest: %s%s' % (manifest['manifest_id'], '' if installed else ' (not recorded: versions differ)'),
              '  Update status: ' + update_status]
    for approval in decisions(store, decision='approve'):
        lines.append('  Approved: %s by %s, %s' % (approval['manifest_id'], approval['approver'],
                                                   'window ' + approval['window_start'] if approval['window_start']
                                                   else 'waiting to run'))
    lines.append('=' * width)
    if any(r['status'] != 'baseline' for r in rows):
        lines.append('  Some components differ from the baseline. Nothing was changed.')
    return '\n'.join(lines)


MENU = """
   1) Reload (check for updates)
   2) Install updates
   3) Choose what to update
   4) Exit
"""


def menu(store, manifest, read=input, write=print):
    rows = inventory(store, manifest)
    status = catalog_status()
    while True:
        write(render(rows, manifest, store, status))
        write(MENU)
        try:
            choice = read('  Enter an option: ').strip()
        except (EOFError, KeyboardInterrupt):
            write('')
            return 0
        if choice == '1':
            rows = inventory(store, manifest)
            status = catalog_status()
            with store.db:
                store.audit('catalog.unavailable', {'reason': 'no catalog configured'}, manifest['manifest_id'])
        elif choice in ('2', '3'):
            write('\n  Installing updates from this menu is not available in this version of PinPoint.\n'
                  '  Approvals are made with: sudo pinpoint-update approve MANIFEST_ID --confirm MANIFEST_ID\n'
                  '  Nothing was changed.\n')
        elif choice == '4':
            return 0
        else:
            write('\n  Please enter 1, 2, 3 or 4.\n')


##################################################
# Command line
##################################################

def pattern_arg(pattern, what):
    def check(text):
        if not re.fullmatch(pattern, text):
            raise argparse.ArgumentTypeError('invalid %s: %r' % (what, text[:80]))
        return text
    return check


def reason_arg(text):
    """Reasons are stored as data, never run: 1 to 500 printable characters on one line."""
    text = text.strip()
    if not 1 <= len(text) <= 500 or not text.isprintable():
        raise argparse.ArgumentTypeError('a reason is 1 to 500 printable characters on one line')
    return text


def time_arg(text):
    """ISO 8601 date and time; without an offset it is the appliance's local time. Returns UTC."""
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?([+-]\d{2}:\d{2}|Z)?', text):
        raise argparse.ArgumentTypeError('expected a date and time such as 2026-11-20T22:00+08:00')
    try:
        moment = datetime.datetime.fromisoformat(text[:-1] + '+00:00' if text.endswith('Z') else text)
    except ValueError:
        raise argparse.ArgumentTypeError('not a valid date and time: %s' % text)
    return utc(moment if moment.tzinfo else moment.astimezone())


def date_arg(text):
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', text):
        raise argparse.ArgumentTypeError('expected a date such as 2026-12-01')
    try:
        return datetime.date.fromisoformat(text).isoformat()
    except ValueError:
        raise argparse.ArgumentTypeError('not a valid date: %s' % text)


def range_arg(low, high):
    def check(text):
        if not re.fullmatch(r'\d{1,6}', text) or not low <= int(text) <= high:
            raise argparse.ArgumentTypeError('expected a number from %d to %d' % (low, high))
        return int(text)
    return check


def build_parser():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument('--json', action='store_true', help='print one JSON object (schema pinpoint-update/v1)')
    manifest_id = pattern_arg(ID_PATTERN, 'manifest ID')
    parser = argparse.ArgumentParser(prog='pinpoint-update', description='PinPoint Update Manager.')
    parser.add_argument('--first-login', action='store_true',
                        help='open the menu once after a fresh install (used by the console login hook)')
    sub = parser.add_subparsers(dest='command', metavar='COMMAND')
    sub.add_parser('menu', help='the numbered console menu (default on a terminal)')
    sub.add_parser('inventory', parents=[common], help='scan the installed versions')
    sub.add_parser('status', parents=[common], help='installed versions, approvals and update status')
    p = sub.add_parser('list', parents=[common], help='recorded manifests and whether they can be installed')
    p.add_argument('--all', action='store_true', help='include revoked manifests')
    p = sub.add_parser('show', parents=[common], help='one manifest, its evidence and limitations')
    p.add_argument('manifest_id', type=manifest_id)
    p = sub.add_parser('validate', parents=[common], help='run the compatibility gate for one manifest')
    p.add_argument('manifest_id', type=manifest_id)
    p = sub.add_parser('approve', parents=[common], help='approve one manifest for this host (admin)')
    p.add_argument('manifest_id', type=manifest_id)
    p.add_argument('--confirm', required=True, type=manifest_id, help='type the manifest ID again')
    p.add_argument('--at', type=time_arg, help='start of the maintenance window (default: no window yet)')
    p.add_argument('--window-minutes', type=range_arg(30, 1440), help='length of the window, 30 to 1440')
    p.add_argument('--accept-limitations', action='store_true', help='confirm a conditional manifest')
    p = sub.add_parser('defer', parents=[common], help='defer one manifest until a review date (admin)')
    p.add_argument('manifest_id', type=manifest_id)
    p.add_argument('--reason', required=True, type=reason_arg)
    p.add_argument('--review-date', required=True, type=date_arg)
    p = sub.add_parser('decline', parents=[common], help='decline one manifest (admin)')
    p.add_argument('manifest_id', type=manifest_id)
    p.add_argument('--reason', required=True, type=reason_arg)
    p = sub.add_parser('cancel', parents=[common], help='cancel an approved transaction (admin)')
    p.add_argument('txn_id', type=pattern_arg(TXN_PATTERN, 'transaction ID'))
    p = sub.add_parser('history', parents=[common], help='past transactions')
    p.add_argument('--limit', type=range_arg(1, 1000), default=20)
    p = sub.add_parser('audit', parents=[common], help='the audit log')
    p.add_argument('--since', type=date_arg, help='only rows from this date (UTC)')
    p.add_argument('--verify', action='store_true', help='check the hash chain')
    return parser


def emit(args, data, text):
    if getattr(args, 'json', False):
        print(json.dumps({'schema': 'pinpoint-update/v1', 'command': args.command, 'result': 'OK', **data},
                         indent=2, sort_keys=True))
    else:
        print(text)


def command_list(store, args, found, problems):
    sql = 'SELECT manifest_id FROM manifest' + ('' if args.all else ' WHERE revoked_at IS NULL')
    items = [manifest_summary(store, store.manifest(mid), found) for (mid,) in store.db.execute(sql + ' ORDER BY 1')]
    lines = ['  %-24s %-9s %-9s %-7s %-13s %s' % ('Manifest', 'Core', 'Plugins', 'NCPA', 'Compatibility', 'Here')]
    installed = store.installed_manifest()
    for item in items:
        here = ('installed' if item['manifest_id'] == installed else 'installable' if item['installable']
                else 'blocked')
        decision = item['latest_decision']
        if decision and decision['status'] == 'active':
            here = {'approve': 'approved', 'defer': 'deferred to ' + str(decision['review_date']),
                    'decline': 'declined'}[decision['decision']]
        v = item['versions']
        lines.append('  %-24s %-9s %-9s %-7s %-13s %s' % (item['manifest_id'], v['nagios-core'], v['nagios-plugins'],
                                                         v['check-ncpa'], item['compat_state'], here))
    for name, problem in sorted(problems.items()):
        lines.append('  REFUSED %s: %s' % (name, problem))
    emit(args, {'installed_manifest': installed, 'manifests': items, 'refused_files': problems}, '\n'.join(lines))
    return OK


def command_show(store, args, found):
    record = store.manifest(args.manifest_id)
    if record is None:
        raise CommandError(INVALID_INPUT, '%s is not a recorded manifest.' % args.manifest_id)
    item, body = manifest_summary(store, record, found), record['body']
    compat = body['compatibility']
    lines = ['  Update set: %s   (digest %s..%s)' % (item['manifest_id'], record['sha256'][:4], record['sha256'][-2:]),
             '  Published: %s by %s' % (body.get('published_at', '-'), body.get('publisher', '-'))]
    for key, label in COMPONENTS:
        lines.append('  %-15s %s' % (label, body['components'][key]['version']))
    lines += ['  Compatibility: %s%s' % (record['compat_state'].upper(),
                                         ' (evidence: %s)' % ', '.join(compat.get('evidence_ids', []))
                                         if compat.get('evidence_ids') else ''),
              '  Upgrades from: %s' % (', '.join(body['upgrade_from']) or 'nothing'),
              '  Migration class: %s   Expected downtime: ~%d min   Rollback: automatic'
              % (body['migration_class'], body.get('expected_downtime_minutes', DEFAULT_DOWNTIME)),
              '  Security fixes: %s' % (', '.join(body.get('security', {}).get('advisories', [])) or 'none listed')]
    for limitation in compat.get('known_limitations', []):
        lines.append('  Limitation: ' + limitation)
    if body.get('release_notes_url'):
        lines.append('  Release notes: ' + body['release_notes_url'])
    lines.append('  On this host: ' + ('can be installed' if item['installable'] else 'BLOCKED'))
    lines += ['    - ' + reason for reason in item['blocked_by']]
    emit(args, {'manifest': item, 'body': body}, '\n'.join(lines))
    return OK


def command_validate(store, args, found):
    reasons = gate(store, args.manifest_id, found)
    with store.db:
        store.audit('manifest.validated', {'result': 'blocked' if reasons else 'installable', 'reasons': reasons},
                    args.manifest_id)
    if reasons:
        raise CommandError(BLOCKED, ' '.join(reasons))
    emit(args, {'manifest_id': args.manifest_id, 'installable': True},
         '  %s can be installed on this host.' % args.manifest_id)
    return OK


def command_history(store, args):
    items = store.rows('SELECT t.txn_id, t.kind, t.source_manifest_id, t.target_manifest_id, t.state, t.failure_code, '
                       't.recovery_status, t.created_at, t.finished_at, t.downtime_seconds, a.approver '
                       'FROM txn t LEFT JOIN approval a ON a.approval_id = t.approval_id WHERE t.host_id = ? '
                       'ORDER BY t.created_at DESC LIMIT ?', (host_id(), args.limit))
    lines = ['  %-27s %-6s %-36s %-11s %-15s %s' % ('Transaction', 'Kind', 'From -> to', 'Approver', 'Result',
                                                    'Recovery')]
    for t in items:
        lines.append('  %-27s %-6s %-36s %-11s %-15s %s' % (
            t['txn_id'], t['kind'], '%s -> %s' % (t['source_manifest_id'], t['target_manifest_id']),
            t['approver'] or '-', t['state'], t['recovery_status'] or '-'))
    emit(args, {'transactions': items}, '\n'.join(lines))
    return OK


def command_audit(store, args):
    broken = store.verify_audit() if args.verify else None
    items = store.rows('SELECT seq, at, actor, event, txn_id, manifest_id, detail_json FROM audit '
                       'WHERE at >= ? ORDER BY seq', (args.since or '',))
    lines = ['%(seq)s %(at)s %(actor)s %(event)s %(manifest_id)s %(detail_json)s' % row for row in items]
    if args.verify:
        lines.append('Audit chain: ' + ('intact' if broken is None else 'BROKEN at row %d' % broken))
    emit(args, {'rows': items, 'chain': None if not args.verify else 'intact' if broken is None else broken},
         '\n'.join(lines))
    return OK if broken is None else 1


def run_command(store, manifest, args):
    command = args.command
    if command == 'menu':
        return menu(store, manifest)
    if command == 'audit':
        return command_audit(store, args)
    found, problems = refresh(store, manifest)
    if command == 'list':
        return command_list(store, args, found, problems)
    if command == 'show':
        return command_show(store, args, found)
    if command == 'validate':
        return command_validate(store, args, found)
    if command == 'history':
        return command_history(store, args)
    if command == 'approve':
        if args.confirm != args.manifest_id:
            raise CommandError(INVALID_INPUT, 'The confirmation does not match the manifest ID. Nothing was approved.')
        approval, txn_id, created = approve(store, args.manifest_id, found, args.at, args.window_minutes,
                                            args.accept_limitations)
        emit(args, {'approval': approval, 'txn_id': txn_id, 'created': created},
             '  %s %s for this host (approval %s, transaction %s, expires %s).\n'
             '  It will be installed by a later version of the Update Manager; nothing was changed now.'
             % ('Approved' if created else 'Already approved:', args.manifest_id, approval['approval_id'], txn_id,
                approval['expires_at']))
        return OK
    if command in ('defer', 'decline'):
        approval, created = refuse(store, args.manifest_id, command, args.reason, getattr(args, 'review_date', None))
        emit(args, {'approval': approval, 'created': created},
             '  %s %s. The installed version keeps running.' % ('Deferred' if command == 'defer' else 'Declined',
                                                                args.manifest_id))
        return OK
    if command == 'cancel':
        changed = cancel(store, args.txn_id)
        emit(args, {'txn_id': args.txn_id, 'changed': changed},
             '  Transaction %s %s.' % (args.txn_id, 'cancelled' if changed else 'was already cancelled'))
        return OK
    rows = compare(found, manifest)
    if args.json:
        emit(args, {'manifest_id': manifest['manifest_id'], 'installed_manifest': store.installed_manifest(),
                    'os': os_profile(), 'pinpoint_commit': app_commit(), 'update_status': catalog_status(),
                    'components': rows, 'approvals': decisions(store, decision='approve'),
                    'active_txn': (active_txn(store) or [None])[0], 'refused_files': problems}, '')
    else:
        print(render(rows, manifest, store, catalog_status()))
    return OK


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if os.geteuid() != 0:
        print('pinpoint-update must be run as root: sudo pinpoint-update', file=sys.stderr)
        return NOT_AUTHORISED
    try:
        manifest = load_manifest()
    except (OSError, ValueError, KeyError) as error:
        print('Baseline manifest is missing or invalid (%s): %s' % (MANIFEST, type(error).__name__), file=sys.stderr)
        return BLOCKED
    if args.first_login:
        if not MENU_PENDING.exists():
            return OK
        # Removed before showing, so a dropped session cannot reopen it on every login.
        MENU_PENDING.unlink()
    store = Store()
    try:
        args.command = 'menu' if args.first_login else args.command or ('menu' if sys.stdin.isatty() else 'status')
        caller = role()
        if caller is None or (args.command in ADMIN_COMMANDS and caller != 'admin'):
            with store.db:
                store.audit('auth.refused', {'command': args.command, 'role': caller})
            raise CommandError(NOT_AUTHORISED, '%s may not run "%s". Ask an administrator to add you to %s.'
                               % (actor(), args.command, VIEWERS if caller is None else ADMINS))
        return run_command(store, manifest, args)
    except InvalidTransition as error:
        return report(args, CommandError(INVALID_TRANSITION, 'Invalid transition: %s' % error))
    except CommandError as error:
        return report(args, error)
    finally:
        store.close()


def report(args, error):
    if getattr(args, 'json', False):
        print(json.dumps({'schema': 'pinpoint-update/v1', 'command': args.command,
                          'result': CODE_NAMES[error.code], 'message': str(error)}, indent=2, sort_keys=True))
    else:
        print('%s: %s' % (CODE_NAMES[error.code], error), file=sys.stderr)
    return error.code


if __name__ == '__main__':
    sys.exit(main())
