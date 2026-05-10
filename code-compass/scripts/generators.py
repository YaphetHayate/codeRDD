import os
import json
from datetime import datetime, timezone

from constants import DIR_ROLE_HINTS


def generate_manifest(project_path, source_files, all_methods, all_entries):
    project_name = os.path.basename(os.path.normpath(project_path))

    total_methods = 0
    files_info = {}

    for sf in source_files:
        rel_path = sf['path']
        abs_path = sf['absolute_path']

        methods_count = 0
        if rel_path in all_methods:
            for cls in all_methods[rel_path].get('classes', []):
                methods_count += len(cls.get('methods', []))

        total_methods += methods_count

        json_name = rel_path.replace('/', '.').replace(os.sep, '.')

        files_info[rel_path] = {
            'language': sf['language'],
            'mtime': all_methods[rel_path]['mtime'] if rel_path in all_methods else 0,
            'hash': _compute_hash_safe(abs_path),
            'methods_count': methods_count,
            'calls_file': f'calls/{json_name}.json',
            'methods_file': f'methods/{json_name}.json',
        }

    return {
        'version': '2.0',
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'project': {
            'name': project_name,
            'type': _detect_project_type(project_path),
            'languages': sorted(set(sf['language'] for sf in source_files)),
            'entry_point': _find_entry_point(project_path, source_files),
        },
        'stats': {
            'total_files': len(source_files),
            'total_methods': total_methods,
            'total_entries': len(all_entries),
        },
        'files': files_info,
    }


def _compute_hash_safe(filepath):
    import hashlib
    try:
        h = hashlib.md5()
        with open(filepath, 'rb') as f:
            for chunk in iter(lambda: f.read(8192), b''):
                h.update(chunk)
        return h.hexdigest()
    except (IOError, OSError):
        return ''


def _detect_project_type(project_path):
    indicators = {
        'package.json': 'Node.js',
        'pyproject.toml': 'Python',
        'requirements.txt': 'Python',
        'setup.py': 'Python',
        'go.mod': 'Go',
        'pom.xml': 'Java (Maven)',
        'build.gradle': 'Java (Gradle)',
        'Cargo.toml': 'Rust',
        'Gemfile': 'Ruby',
    }
    for name, ptype in indicators.items():
        if os.path.exists(os.path.join(project_path, name)):
            return ptype
    return 'Unknown'


def _find_entry_point(project_path, source_files):
    candidates = ['main.py', 'main.go', 'main.java', 'main.ts', 'main.js',
                  'app.py', 'app.ts', 'app.js', 'index.py', 'index.ts', 'index.js',
                  'manage.py', 'server.py', 'server.ts', 'server.js']
    for sf in source_files:
        basename = os.path.basename(sf['path'])
        if basename in candidates:
            return sf['path']
    return ''


def generate_overview(project_path, source_files, all_methods, all_entries):
    project_name = os.path.basename(os.path.normpath(project_path))

    total_methods = sum(
        sum(len(cls.get('methods', [])) for cls in all_methods.get(sf['path'], {}).get('classes', []))
        for sf in source_files
    )

    lines = []
    lines.append(f'# 项目代码全景图\n')
    lines.append(f'> 生成时间：{datetime.now().strftime("%Y-%m-%d %H:%M")}')
    lines.append(f'> 项目：{project_name} | 源码文件：{len(source_files)} | 方法/函数：{total_methods}\n')

    dir_tree = _build_dir_tree(source_files, all_methods)
    lines.append('## 目录结构\n')
    lines.append('```')
    lines.append(f'{project_name}/')
    lines.extend(dir_tree)
    lines.append('```\n')

    if all_entries:
        lines.append('---\n')
        lines.append('## 入口点\n')
        lines.append('| 入口 | 类型 | 文件 | 描述 |')
        lines.append('|------|------|------|------|')
        for entry in all_entries:
            desc = entry.get('description', '')
            if not desc and entry.get('stale'):
                desc = '(待生成)'
            entry_id = entry.get('id', '')
            entry_type = entry.get('type', '')
            entry_file = entry.get('file', '')
            lines.append(f'| {entry_id} | {entry_type} | {entry_file} | {desc} |')

    return '\n'.join(lines)


def _build_dir_tree(source_files, all_methods):
    dir_stats = {}
    for sf in source_files:
        parts = sf['path'].split('/')
        for i in range(len(parts)):
            dir_path = '/'.join(parts[:i + 1]) if i > 0 else parts[0]
            if dir_path not in dir_stats:
                dir_stats[dir_path] = {'files': 0, 'methods': 0, 'is_file': False}
            if i == len(parts) - 1:
                dir_stats[dir_path]['is_file'] = True
                dir_stats[dir_path]['files'] = 1
                methods_count = sum(
                    len(cls.get('methods', []))
                    for cls in all_methods.get(sf['path'], {}).get('classes', [])
                )
                dir_stats[dir_path]['methods'] = methods_count
            else:
                dir_stats[dir_path]['files'] = dir_stats[dir_path].get('files', 0)

    for sf in source_files:
        parts = sf['path'].split('/')
        for i in range(len(parts) - 1):
            dir_path = '/'.join(parts[:i + 1])
            if dir_path in dir_stats:
                methods_count = sum(
                    len(cls.get('methods', []))
                    for cls in all_methods.get(sf['path'], {}).get('classes', [])
                )
                dir_stats[dir_path]['methods'] = dir_stats[dir_path].get('methods', 0) + methods_count

    lines = []
    top_dirs = sorted(set(
        sf['path'].split('/')[0]
        for sf in source_files
        if '/' in sf['path']
    ))
    top_files = sorted(
        sf['path'] for sf in source_files
        if '/' not in sf['path']
    )

    all_top = []
    for d in top_dirs:
        stat = dir_stats.get(d, {})
        role = DIR_ROLE_HINTS.get(d, '')
        role_str = f' # {role}' if role else ''
        file_count = stat.get('files', 0)
        method_count = stat.get('methods', 0)
        info = f'{file_count} files'
        if method_count:
            info += f', {method_count} methods'
        all_top.append((d + '/', f'{role_str} ({info})'))
    for f in top_files:
        all_top.append((f, ''))

    for i, (name, info) in enumerate(all_top):
        prefix = '└──' if i == len(all_top) - 1 else '├──'
        lines.append(f'{prefix} {name}{info}')

    return lines


def build_reverse_index(all_calls):
    callee_index = {}
    for rel_path, calls_data in all_calls.items():
        for call in calls_data.get('calls', []):
            callee_file = call.get('callee_file')
            if callee_file and callee_file in all_calls:
                if callee_file not in callee_index:
                    callee_index[callee_file] = []
                callee_index[callee_file].append({
                    'callee': call['callee'],
                    'caller': call['caller'],
                    'caller_file': rel_path,
                    'caller_line': call['caller_line'],
                })

    for callee_file, callers in callee_index.items():
        if callee_file in all_calls:
            all_calls[callee_file]['called_by'] = callers


def generate_entries_json(all_entries):
    return {
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'stale': False,
        'entries': all_entries,
    }


def generate_pending(all_calls, all_entries):
    unresolved = []
    entries_no_desc = []

    for rel_path, calls_data in all_calls.items():
        for call in calls_data.get('calls', []):
            if call.get('confidence') == 'low' and call.get('callee_file') is None:
                unresolved.append({
                    'file': rel_path,
                    'caller': call['caller'],
                    'caller_line': call['caller_line'],
                    'callee': call['callee'],
                    'confidence': 'low',
                    'hint': '无法确定调用目标来源文件',
                })

    for entry in all_entries:
        if not entry.get('description', '').strip():
            entries_no_desc.append({
                'id': entry.get('id', ''),
                'type': entry.get('type', ''),
                'file': entry.get('file', ''),
                'handler': entry.get('handler', ''),
                'stale': entry.get('stale', False),
            })

    return {
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'summary': {
            'total_unresolved_calls': len(unresolved),
            'total_entries_without_description': len(entries_no_desc),
        },
        'unresolved_calls': unresolved,
        'entries_without_description': entries_no_desc,
    }
