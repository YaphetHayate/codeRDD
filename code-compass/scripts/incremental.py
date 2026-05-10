import os
import json
import hashlib

from constants import EXCLUDE_DIRS, CODE_EXTENSIONS
from parsers import get_parser
from extractors import compute_file_hash, get_file_mtime, path_to_json_name
from generators import build_reverse_index


def detect_changes(project_path, manifest):
    current_files = {}
    for root, dirs, files in os.walk(project_path):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS and not d.startswith('.')]
        for f in files:
            filepath = os.path.join(root, f)
            rel_path = os.path.relpath(filepath, project_path).replace(os.sep, '/')
            ext = os.path.splitext(f)[1]
            if ext in CODE_EXTENSIONS:
                current_files[rel_path] = filepath

    old_files = manifest.get('files', {})

    added = []
    modified = []
    deleted = []
    unchanged = []

    for rel_path, abs_path in current_files.items():
        if rel_path not in old_files:
            added.append(rel_path)
        else:
            old_mtime = old_files[rel_path].get('mtime', 0)
            new_mtime = get_file_mtime(abs_path)
            if old_mtime != new_mtime:
                old_hash = old_files[rel_path].get('hash', '')
                new_hash = compute_file_hash(abs_path)
                if old_hash != new_hash:
                    modified.append(rel_path)
                else:
                    unchanged.append(rel_path)
            else:
                unchanged.append(rel_path)

    for rel_path in old_files:
        if rel_path not in current_files:
            deleted.append(rel_path)

    return {
        'added': added,
        'modified': modified,
        'deleted': deleted,
        'unchanged': unchanged,
    }


def incremental_update(project_path, output_dir, changes):
    from .extractors import extract_files, detect_entries_for_files, scan_source_files

    changed_files = changes['added'] + changes['modified']
    deleted_files = changes['deleted']

    source_files = []
    for rel_path in changed_files:
        abs_path = os.path.join(project_path, rel_path)
        ext = os.path.splitext(rel_path)[1]
        if ext in CODE_EXTENSIONS:
            source_files.append({
                'path': rel_path,
                'absolute_path': abs_path,
                'language': CODE_EXTENSIONS[ext],
                'ext': ext,
            })

    all_methods, all_imports, all_calls = extract_files(source_files, project_path)

    for rel_path in changed_files:
        if rel_path in all_methods:
            methods_json = os.path.join(output_dir, 'methods', f'{path_to_json_name(rel_path)}.json')
            _write_json(methods_json, all_methods[rel_path])

    for rel_path in changed_files:
        if rel_path in all_calls:
            calls_json = os.path.join(output_dir, 'calls', f'{path_to_json_name(rel_path)}.json')
            _write_json(calls_json, all_calls[rel_path])

    for rel_path in deleted_files:
        methods_json = os.path.join(output_dir, 'methods', f'{path_to_json_name(rel_path)}.json')
        calls_json = os.path.join(output_dir, 'calls', f'{path_to_json_name(rel_path)}.json')
        if os.path.exists(methods_json):
            os.remove(methods_json)
        if os.path.exists(calls_json):
            os.remove(calls_json)

    _rebuild_reverse_index(output_dir)

    new_entries = detect_entries_for_files(source_files, project_path)
    _update_entries(output_dir, new_entries, deleted_files, changed_files)

    return all_methods, all_imports, all_calls


def _rebuild_reverse_index(output_dir):
    calls_dir = os.path.join(output_dir, 'calls')
    if not os.path.exists(calls_dir):
        return

    all_calls = {}
    for fname in os.listdir(calls_dir):
        if fname.endswith('.json'):
            filepath = os.path.join(calls_dir, fname)
            try:
                with open(filepath, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                data['called_by'] = []
                all_calls[data.get('file', '')] = data
            except (json.JSONDecodeError, IOError):
                continue

    build_reverse_index(all_calls)

    for rel_path, data in all_calls.items():
        json_name = path_to_json_name(rel_path)
        filepath = os.path.join(calls_dir, f'{json_name}.json')
        _write_json(filepath, data)


def _update_entries(output_dir, new_entries, deleted_files, modified_files):
    entries_path = os.path.join(output_dir, 'entries.json')
    existing = {}
    if os.path.exists(entries_path):
        try:
            with open(entries_path, 'r', encoding='utf-8') as f:
                existing = json.load(f)
        except (json.JSONDecodeError, IOError):
            existing = {'entries': []}

    entries_list = existing.get('entries', [])

    entries_list = [
        e for e in entries_list
        if e.get('file') not in deleted_files
    ]

    for entry in entries_list:
        if entry.get('file') in modified_files:
            old_calls = set(entry.get('calls', []))
            calls_dir = os.path.join(output_dir, 'calls')
            json_name = path_to_json_name(entry.get('file', ''))
            calls_path = os.path.join(calls_dir, f'{json_name}.json')
            new_calls = set()
            if os.path.exists(calls_path):
                try:
                    with open(calls_path, 'r', encoding='utf-8') as f:
                        calls_data = json.load(f)
                    handler = entry.get('handler', '')
                    for call in calls_data.get('calls', []):
                        caller = call.get('caller', '')
                        caller_name = caller.split('.')[-1] if '.' in caller else caller
                        if caller_name == handler:
                            new_calls.add(call.get('callee', ''))
                except (json.JSONDecodeError, IOError):
                    pass

            if old_calls != new_calls:
                entry['stale'] = True
            entry['calls'] = list(new_calls)

    for entry in new_entries:
        existing_ids = {e.get('id') for e in entries_list}
        if entry.get('id') not in existing_ids:
            entries_list.append(entry)

    existing['entries'] = entries_list
    existing['generated_at'] = _now_iso()
    _write_json(entries_path, existing)


def _write_json(filepath, data):
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    with open(filepath, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def _now_iso():
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat()
