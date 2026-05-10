import os
import sys
import json
import argparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from extractors import scan_source_files, extract_all, path_to_json_name, get_file_mtime
from generators import (
    generate_manifest, generate_overview, build_reverse_index,
    generate_entries_json, generate_pending,
)
from incremental import detect_changes, incremental_update


def main():
    parser = argparse.ArgumentParser(description='Code Compass Index Builder')
    parser.add_argument('project_path', nargs='?', default='.', help='项目根目录')
    parser.add_argument('--refresh', action='store_true', help='刷新所有 stale 入口')
    args = parser.parse_args()

    project_path = os.path.abspath(args.project_path)
    if not os.path.isdir(project_path):
        print(f'错误: {project_path} 不是有效目录')
        sys.exit(1)

    output_dir = os.path.join(project_path, '.code-compass')

    if os.path.exists(os.path.join(output_dir, 'manifest.json')):
        print('检测到已有索引，执行增量更新...')
        _incremental_build(project_path, output_dir, args.refresh)
    else:
        print('未检测到已有索引，执行全量构建...')
        _full_build(project_path, output_dir)

    print('构建完成。')


def _full_build(project_path, output_dir):
    os.makedirs(os.path.join(output_dir, 'methods'), exist_ok=True)
    os.makedirs(os.path.join(output_dir, 'calls'), exist_ok=True)

    source_files = scan_source_files(project_path)
    if not source_files:
        print('未发现源码文件。')
        return

    print(f'扫描到 {len(source_files)} 个源码文件')

    all_methods, all_imports, all_calls, all_entries = extract_all(source_files, project_path)

    build_reverse_index(all_calls)

    manifest = generate_manifest(project_path, source_files, all_methods, all_entries)
    overview = generate_overview(project_path, source_files, all_methods, all_entries)
    entries_json = generate_entries_json(all_entries)
    pending = generate_pending(all_calls, all_entries)

    _write_json(os.path.join(output_dir, 'manifest.json'), manifest)
    _write_text(os.path.join(output_dir, 'overview.md'), overview)
    _write_json(os.path.join(output_dir, 'entries.json'), entries_json)
    _write_json(os.path.join(output_dir, 'pending.json'), pending)

    for rel_path, methods_data in all_methods.items():
        json_name = path_to_json_name(rel_path)
        _write_json(os.path.join(output_dir, 'methods', f'{json_name}.json'), methods_data)

    for rel_path, calls_data in all_calls.items():
        json_name = path_to_json_name(rel_path)
        _write_json(os.path.join(output_dir, 'calls', f'{json_name}.json'), calls_data)

    print(f'  方法签名: {sum(m["methods_count"] for m in manifest["files"].values())} 个')
    print(f'  入口点: {len(all_entries)} 个')
    print(f'  待AI补充调用: {pending["summary"]["total_unresolved_calls"]} 项')
    print(f'  待AI生成描述: {pending["summary"]["total_entries_without_description"]} 项')


def _incremental_build(project_path, output_dir, refresh):
    manifest_path = os.path.join(output_dir, 'manifest.json')
    try:
        with open(manifest_path, 'r', encoding='utf-8') as f:
            manifest = json.load(f)
    except (json.JSONDecodeError, IOError):
        print('manifest.json 损坏，执行全量重建...')
        _full_build(project_path, output_dir)
        return

    changes = detect_changes(project_path, manifest)
    total_changed = len(changes['added']) + len(changes['modified']) + len(changes['deleted'])

    if total_changed == 0 and not refresh:
        print('没有检测到文件变更。')
        return

    if total_changed > 0:
        print(f'  新增: {len(changes["added"])} 修改: {len(changes["modified"])} 删除: {len(changes["deleted"])}')

        all_methods, all_imports, all_calls = incremental_update(project_path, output_dir, changes)

        all_source_files = scan_source_files(project_path)

        entries_path = os.path.join(output_dir, 'entries.json')
        all_entries = []
        if os.path.exists(entries_path):
            try:
                with open(entries_path, 'r', encoding='utf-8') as f:
                    entries_data = json.load(f)
                all_entries = entries_data.get('entries', [])
            except (json.JSONDecodeError, IOError):
                pass

        for sf in all_source_files:
            if sf['path'] in changes['added'] or sf['path'] in changes['modified']:
                abs_path = os.path.join(project_path, sf['path'])
                try:
                    with open(abs_path, 'r', encoding='utf-8', errors='replace') as f:
                        content = f.read()
                except IOError:
                    continue
                from parsers import get_parser
                p = get_parser(abs_path)
                if p:
                    file_entries = p.detect_entries(content, sf['path'])
                    for e in file_entries:
                        if not e.get('description'):
                            e['description'] = ''
                        if 'stale' not in e:
                            e['stale'] = True

        _update_manifest(project_path, manifest, all_source_files, all_methods, all_entries, changes, output_dir)

        overview = generate_overview(project_path, all_source_files,
                                     _load_all_methods(output_dir), all_entries)
        _write_text(os.path.join(output_dir, 'overview.md'), overview)

    if refresh:
        _mark_all_entries_stale(output_dir)

    pending = _generate_pending_from_disk(output_dir)
    _write_json(os.path.join(output_dir, 'pending.json'), pending)
    print(f'  待AI补充调用: {pending["summary"]["total_unresolved_calls"]} 项')
    print(f'  待AI生成描述: {pending["summary"]["total_entries_without_description"]} 项')


def _update_manifest(project_path, manifest, source_files, all_methods, all_entries, changes, output_dir):
    import hashlib

    for rel_path in changes['added'] + changes['modified']:
        abs_path = os.path.join(project_path, rel_path)
        methods_count = 0
        if rel_path in all_methods:
            for cls in all_methods[rel_path].get('classes', []):
                methods_count += len(cls.get('methods', []))

        json_name = path_to_json_name(rel_path)
        manifest['files'][rel_path] = {
            'language': manifest['files'].get(rel_path, {}).get('language', ''),
            'mtime': get_file_mtime(abs_path) if os.path.exists(abs_path) else 0,
            'hash': _compute_hash(abs_path),
            'methods_count': methods_count,
            'calls_file': f'calls/{json_name}.json',
            'methods_file': f'methods/{json_name}.json',
        }
        ext = os.path.splitext(rel_path)[1]
        from constants import CODE_EXTENSIONS
        if ext in CODE_EXTENSIONS:
            manifest['files'][rel_path]['language'] = CODE_EXTENSIONS[ext]

    for rel_path in changes['deleted']:
        manifest['files'].pop(rel_path, None)

    manifest['stats']['total_files'] = len(manifest['files'])
    manifest['stats']['total_methods'] = sum(
        f.get('methods_count', 0) for f in manifest['files'].values()
    )
    manifest['stats']['total_entries'] = len(all_entries)

    _write_json(os.path.join(output_dir, 'manifest.json'), manifest)


def _mark_all_entries_stale(output_dir):
    entries_path = os.path.join(output_dir, 'entries.json')
    if not os.path.exists(entries_path):
        return
    try:
        with open(entries_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
        for entry in data.get('entries', []):
            entry['stale'] = True
        data['stale'] = True
        _write_json(entries_path, data)
    except (json.JSONDecodeError, IOError):
        pass


def _generate_pending_from_disk(output_dir):
    calls_dir = os.path.join(output_dir, 'calls')
    entries_path = os.path.join(output_dir, 'entries.json')

    unresolved = []
    if os.path.isdir(calls_dir):
        for fname in os.listdir(calls_dir):
            if not fname.endswith('.json'):
                continue
            try:
                with open(os.path.join(calls_dir, fname), 'r', encoding='utf-8') as f:
                    data = json.load(f)
                for call in data.get('calls', []):
                    if call.get('confidence') == 'low' and call.get('callee_file') is None:
                        unresolved.append({
                            'file': data['file'],
                            'caller': call['caller'],
                            'caller_line': call['caller_line'],
                            'callee': call['callee'],
                            'confidence': 'low',
                            'hint': '无法确定调用目标来源文件',
                        })
            except (json.JSONDecodeError, IOError):
                continue

    entries_no_desc = []
    if os.path.exists(entries_path):
        try:
            with open(entries_path, 'r', encoding='utf-8') as f:
                data = json.load(f)
            for entry in data.get('entries', []):
                if not entry.get('description', '').strip():
                    entries_no_desc.append({
                        'id': entry.get('id', ''),
                        'type': entry.get('type', ''),
                        'file': entry.get('file', ''),
                        'handler': entry.get('handler', ''),
                        'stale': entry.get('stale', False),
                    })
        except (json.JSONDecodeError, IOError):
            pass

    from datetime import datetime, timezone
    return {
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'summary': {
            'total_unresolved_calls': len(unresolved),
            'total_entries_without_description': len(entries_no_desc),
        },
        'unresolved_calls': unresolved,
        'entries_without_description': entries_no_desc,
    }


def _load_all_methods(output_dir):
    methods_dir = os.path.join(output_dir, 'methods')
    result = {}
    if os.path.isdir(methods_dir):
        for fname in os.listdir(methods_dir):
            if fname.endswith('.json'):
                try:
                    with open(os.path.join(methods_dir, fname), 'r', encoding='utf-8') as f:
                        data = json.load(f)
                    result[data.get('file', '')] = data
                except (json.JSONDecodeError, IOError):
                    continue
    return result


def _compute_hash(filepath):
    import hashlib
    try:
        h = hashlib.md5()
        with open(filepath, 'rb') as f:
            for chunk in iter(lambda: f.read(8192), b''):
                h.update(chunk)
        return h.hexdigest()
    except (IOError, OSError):
        return ''


def _write_json(filepath, data):
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    with open(filepath, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def _write_text(filepath, text):
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(text)


if __name__ == '__main__':
    main()
