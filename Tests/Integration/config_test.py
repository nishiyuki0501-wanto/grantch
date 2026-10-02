"""Exercise installer round-trip in an isolated home; never edits real CLI config."""
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
config = root / '.build/release/grantch-config'
bridge = root / '.build/release/grantch-hook'


def run(home, *args, lang='en'):
    env = dict(os.environ, GRANTCH_CONFIG_HOME=str(home), GRANTCH_LANG=lang)
    return subprocess.run([str(config), *args], env=env, check=True, capture_output=True, text=True)


with tempfile.TemporaryDirectory(prefix='grantch-config-') as directory:
    home = Path(directory)
    paths = ['.claude/settings.json', '.codex/hooks.json', '.gemini/config/hooks.json']
    fixtures = [
        {'theme': 'keep', 'hooks': {'PermissionRequest': [{'hooks': [{'type': 'command', 'command': 'other-hook'}]}]}},
        {'hooks': {'PostToolUse': [{'hooks': [{'command': 'other-post-hook', 'type': 'command'}]}], 'Stop': [{'hooks': []}]}},
        {'unrelated': {'Stop': [{'type': 'command', 'command': 'other-agy-hook'}]}}
    ]
    for relative, fixture in zip(paths, fixtures):
        path = home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(fixture))
    (home / paths[1]).chmod(0o644)
    # Dotfile managers symlink settings; the installer must write through the link.
    claude_target = home / 'dotfiles/claude-settings.json'
    claude_target.parent.mkdir()
    (home / paths[0]).rename(claude_target)
    (home / paths[0]).symlink_to(claude_target)

    run(home, 'install', str(bridge))
    installed = [(home / path).read_bytes() for path in paths]
    run(home, 'install', str(bridge))
    assert installed == [(home / path).read_bytes() for path in paths], 'install is not idempotent'
    agy = json.loads((home / paths[2]).read_text())
    assert 'grantch-approval' in agy

    backups = sorted(home.rglob('*.grantch-backup-*'))
    assert len(backups) == 3, backups
    assert not list((home / 'dotfiles').glob('*.grantch-backup-*')), 'backup written into the dotfiles repository'
    assert all(stat.S_IMODE(b.stat().st_mode) == 0o600 for b in backups), 'backups must be private'
    assert stat.S_IMODE((home / paths[1]).stat().st_mode) == 0o644, 'existing file mode changed'

    run(home, 'uninstall')
    for relative, fixture in zip(paths, fixtures):
        restored = json.loads((home / relative).read_text())
        assert restored == fixture, (relative, restored)
    assert not (home / 'Library/Application Support/Grantch/bin/grantch-hook').exists()
    assert (home / paths[0]).is_symlink(), 'symlinked settings were replaced'

with tempfile.TemporaryDirectory(prefix='grantch-config-') as directory:
    home = Path(directory)
    (home / '.claude').mkdir()
    # A dangling link is filled in, not replaced by a regular file.
    (home / '.claude/settings.json').symlink_to(home / 'dotfiles/settings.json')
    (home / 'dotfiles').mkdir()
    output = run(home, 'install', str(bridge)).stdout
    assert (home / '.claude/settings.json').is_symlink()
    assert 'PermissionRequest' in json.loads((home / 'dotfiles/settings.json').read_text())['hooks']
    assert not (home / '.codex').exists() and not (home / '.gemini').exists(), 'created config for absent CLIs'
    assert 'Skipped Codex CLI' in output and 'Skipped Antigravity CLI' in output

with tempfile.TemporaryDirectory(prefix='grantch-config-') as directory:
    home = Path(directory)
    # ~/.claude -> dotfiles/claude, settings.json -> ../shared/settings.json:
    # the relative target resolves from the real directory, dotfiles/claude.
    (home / 'dotfiles/claude').mkdir(parents=True)
    (home / 'dotfiles/shared').mkdir()
    (home / 'dotfiles/shared/settings.json').write_text('{"theme": "keep"}')
    (home / '.claude').symlink_to(home / 'dotfiles/claude')
    (home / 'dotfiles/claude/settings.json').symlink_to('../shared/settings.json')
    run(home, 'install', str(bridge))
    assert 'hooks' in json.loads((home / 'dotfiles/shared/settings.json').read_text())
    assert not (home / 'shared').exists(), 'relative link resolved from the wrong directory'

with tempfile.TemporaryDirectory(prefix='grantch-config-') as directory:
    for lang, expected in [('en', 'No ~/.claude'), ('ja', 'のどれも見つかりません')]:
        env = dict(os.environ, GRANTCH_CONFIG_HOME=directory, GRANTCH_LANG=lang)
        result = subprocess.run([str(config), 'install', str(bridge)], env=env, capture_output=True, text=True)
        assert result.returncode != 0 and expected in result.stderr, result.stderr

with tempfile.TemporaryDirectory(prefix='grantch-config-') as directory:
    home = Path(directory)
    (home / '.claude').mkdir()
    output = run(home, 'install', str(bridge), lang='ja').stdout
    assert 'Claude Code の承認フックをインストールしました' in output, output
    status = json.loads((home / '.claude/settings.json').read_text())['hooks']['PermissionRequest'][0]['hooks'][0]['statusMessage']
    assert status == 'にゃんこのスタミナで承認待ち', status

print('PASS: installer idempotence, exact uninstall, private backups beside links, modes kept, '
      'symlinks (including dangling) kept, absent CLIs skipped, Japanese and English messages')
