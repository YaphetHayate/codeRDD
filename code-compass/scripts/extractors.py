import os
import json
import hashlib

from constants import EXCLUDE_DIRS, CODE_EXTENSIONS, FILE_LIMIT, SKIP_METHOD_NAMES
from parsers import get_parser


def load_skip_methods(project_path):
    skip_methods = set(SKIP_METHOD_NAMES)
    filters_path = os.path.join(project_path, '.code-compass', 'filters.json')
    if os.path.exists(filters_path):
        try:
            with open(filters_path, 'r', encoding='utf-8') as f:
                filters = json.load(f)
            for name in filters.get('skip_methods', []):
                skip_methods.add(name)
        except (json.JSONDecodeError, IOError):
            pass
    return frozenset(skip_methods)


def _filter_calls(calls, skip_methods):
    filtered = []
    for call in calls:
        callee = call.get('callee', '')
        if '.' in callee:
            method = callee.rsplit('.', 1)[-1]
            if method in skip_methods:
                continue
        else:
            if callee in skip_methods:
                continue
        if callee in ('except', 'in'):
            continue
        filtered.append(call)
    return filtered


def scan_source_files(project_path):
    source_files = []
    project_path = os.path.normpath(project_path)

    for root, dirs, files in os.walk(project_path):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS and not d.startswith('.')]

        for f in files:
            filepath = os.path.join(root, f)
            rel_path = os.path.relpath(filepath, project_path)
            ext = os.path.splitext(f)[1]

            if ext in CODE_EXTENSIONS:
                source_files.append({
                    'path': rel_path.replace(os.sep, '/'),
                    'absolute_path': filepath,
                    'language': CODE_EXTENSIONS[ext],
                    'ext': ext,
                })

    source_files.sort(key=lambda x: x['path'])
    return source_files


def compute_file_hash(filepath):
    h = hashlib.md5()
    with open(filepath, 'rb') as f:
        for chunk in iter(lambda: f.read(8192), b''):
            h.update(chunk)
    return h.hexdigest()


def get_file_mtime(filepath):
    return int(os.path.getmtime(filepath))


def path_to_json_name(rel_path):
    return rel_path.replace('/', '.').replace(os.sep, '.')


def extract_all(source_files, project_path):
    all_methods = {}
    all_imports = {}
    all_calls = {}
    all_entries = []
    skip_methods = load_skip_methods(project_path)

    for sf in source_files:
        rel_path = sf['path']
        abs_path = sf['absolute_path']
        parser = get_parser(abs_path)
        if parser is None:
            continue

        try:
            with open(abs_path, 'r', encoding='utf-8', errors='replace') as f:
                content = f.read()
        except (IOError, OSError):
            continue

        methods = parser.extract_methods(content, rel_path)
        methods['mtime'] = get_file_mtime(abs_path)
        all_methods[rel_path] = methods

        imports = parser.extract_imports(content, rel_path)
        all_imports[rel_path] = imports

        known_methods = _build_known_methods(all_methods)
        calls = parser.extract_calls(content, rel_path, imports, known_methods)
        calls = _filter_calls(calls, skip_methods)
        all_calls[rel_path] = {
            'file': rel_path,
            'mtime': get_file_mtime(abs_path),
            'calls': calls,
            'called_by': [],
        }

        entries = parser.detect_entries(content, rel_path)
        for entry in entries:
            if 'calls' not in entry:
                handler_calls = _get_handler_calls(entry.get('handler', ''), calls)
                entry['calls'] = handler_calls
            if 'description' not in entry:
                entry['description'] = ''
            if 'stale' not in entry:
                entry['stale'] = True
        all_entries.extend(entries)

    return all_methods, all_imports, all_calls, all_entries


def _build_known_methods(all_methods):
    known = {}
    for rel_path, methods_data in all_methods.items():
        for cls in methods_data.get('classes', []):
            cls_name = cls['name']
            for method in cls.get('methods', []):
                method_name = method['name']
                if cls_name == 'module_level':
                    if method_name not in known:
                        known[method_name] = []
                    known[method_name].append(rel_path)
                else:
                    full_name = f"{cls_name}.{method_name}"
                    if full_name not in known:
                        known[full_name] = []
                    known[full_name].append(rel_path)
    return known


def _get_handler_calls(handler_name, calls_list):
    result = []
    for call in calls_list:
        caller = call['caller']
        caller_name = caller.split('.')[-1] if '.' in caller else caller
        if caller_name == handler_name:
            result.append(call['callee'])
    return result


def extract_files(source_files, project_path):
    all_methods = {}
    all_imports = {}
    all_calls = {}
    skip_methods = load_skip_methods(project_path)

    for sf in source_files:
        rel_path = sf['path']
        abs_path = sf['absolute_path']
        parser = get_parser(abs_path)
        if parser is None:
            continue

        try:
            with open(abs_path, 'r', encoding='utf-8', errors='replace') as f:
                content = f.read()
        except (IOError, OSError):
            continue

        methods = parser.extract_methods(content, rel_path)
        methods['mtime'] = get_file_mtime(abs_path)
        all_methods[rel_path] = methods

        imports = parser.extract_imports(content, rel_path)
        all_imports[rel_path] = imports

        calls = parser.extract_calls(content, rel_path, imports, {})
        calls = _filter_calls(calls, skip_methods)
        all_calls[rel_path] = {
            'file': rel_path,
            'mtime': get_file_mtime(abs_path),
            'calls': calls,
            'called_by': [],
        }

    return all_methods, all_imports, all_calls


def detect_entries_for_files(source_files, project_path):
    entries = []
    for sf in source_files:
        rel_path = sf['path']
        abs_path = sf['absolute_path']
        parser = get_parser(abs_path)
        if parser is None:
            continue

        try:
            with open(abs_path, 'r', encoding='utf-8', errors='replace') as f:
                content = f.read()
        except (IOError, OSError):
            continue

        file_entries = parser.detect_entries(content, rel_path)
        for entry in file_entries:
            if 'description' not in entry:
                entry['description'] = ''
            if 'stale' not in entry:
                entry['stale'] = True
        entries.extend(file_entries)

    return entries
