import re
import os

from .base import BaseParser


class TypeScriptParser(BaseParser):

    SKIP_CALL_PATTERNS = {
        'console', 'Math', 'JSON', 'Object', 'Array', 'String', 'Number',
        'Boolean', 'Promise', 'Symbol', 'Date', 'RegExp', 'Error', 'Map',
        'Set', 'WeakMap', 'WeakSet', 'parseInt', 'parseFloat', 'isNaN',
        'isFinite', 'encodeURI', 'decodeURI', 'setTimeout', 'setInterval',
        'clearTimeout', 'clearInterval', 'fetch', 'Reflect',
    }

    RE_FUNC = re.compile(r'(?:export\s+)?(?:async\s+)?function\s+(\w+)\s*\(([^)]*)\)')
    RE_ARROW = re.compile(r'(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s+)?\(([^)]*)\)\s*(?::\s*[^=]+)?\s*=>')
    RE_METHOD = re.compile(r'(?:public|private|protected|static|async|get|set|readonly)\s+(\w+)\s*\(([^)]*)\)')
    RE_CLASS = re.compile(r'(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+(\w+)')

    RE_IMPORT_DESTRUCT = re.compile(r"import\s+\{([^}]+)\}\s+from\s+['\"]([^'\"]+)['\"]")
    RE_IMPORT_DEFAULT = re.compile(r"import\s+(\w+)\s+from\s+['\"]([^'\"]+)['\"]")
    RE_IMPORT_STAR = re.compile(r"import\s+\*\s+as\s+(\w+)\s+from\s+['\"]([^'\"]+)['\"]")

    RE_ENTRY_EXPRESS = re.compile(r'(?:app|router)\.(get|post|put|delete|patch)\s*\(\s*[\'"]([^\'"]*)[\'"]')
    RE_ENTRY_NESTJS = re.compile(r'@(Get|Post|Put|Delete|Patch|Controller)\s*\(\s*[\'"]?([^\'")\s]*)')

    RE_CALL = re.compile(r'(\w+(?:\.\w+)*)\s*\(')

    CONTROL_KEYWORDS = frozenset({
        'if', 'for', 'while', 'switch', 'catch', 'function', 'return',
        'throw', 'new', 'typeof', 'instanceof', 'delete', 'void',
        'class', 'const', 'let', 'var', 'import', 'export',
    })

    def extract_methods(self, content, filepath):
        classes = []
        current_class = None
        class_methods = []

        lines = content.split('\n')
        brace_depth = 0
        class_brace_depth = {}

        for line_idx, line in enumerate(lines):
            stripped = line.strip()

            if stripped.startswith('//') or stripped.startswith('/*') or stripped.startswith('*'):
                continue

            cls_m = self.RE_CLASS.search(stripped)
            if cls_m:
                if current_class and class_methods:
                    classes.append({'name': current_class, 'methods': class_methods})
                current_class = cls_m.group(1)
                class_methods = []
                class_brace_depth[current_class] = brace_depth + stripped.count('{') - stripped.count('}')
                continue

            if current_class:
                method_m = self.RE_METHOD.search(stripped)
                if method_m and method_m.group(1) not in self.CONTROL_KEYWORDS:
                    docstring = self._extract_jsdoc(lines, line_idx)
                    class_methods.append({
                        'name': method_m.group(1),
                        'signature': stripped.rstrip('{').strip(),
                        'line': line_idx + 1,
                        'docstring': docstring,
                    })
                    continue

            func_m = self.RE_FUNC.search(stripped)
            if func_m:
                if current_class and class_methods:
                    classes.append({'name': current_class, 'methods': class_methods})
                    current_class = None
                    class_methods = []
                docstring = self._extract_jsdoc(lines, line_idx)
                if not any(c['name'] == 'module_level' for c in classes):
                    classes.append({'name': 'module_level', 'methods': []})
                ml = next(c for c in classes if c['name'] == 'module_level')
                ml['methods'].append({
                    'name': func_m.group(1),
                    'signature': stripped,
                    'line': line_idx + 1,
                    'docstring': docstring,
                })
                continue

            arrow_m = self.RE_ARROW.search(stripped)
            if arrow_m:
                if current_class and class_methods:
                    classes.append({'name': current_class, 'methods': class_methods})
                    current_class = None
                    class_methods = []
                docstring = self._extract_jsdoc(lines, line_idx)
                if not any(c['name'] == 'module_level' for c in classes):
                    classes.append({'name': 'module_level', 'methods': []})
                ml = next(c for c in classes if c['name'] == 'module_level')
                ml['methods'].append({
                    'name': arrow_m.group(1),
                    'signature': stripped,
                    'line': line_idx + 1,
                    'docstring': docstring,
                })

        if current_class and class_methods:
            classes.append({'name': current_class, 'methods': class_methods})

        return {
            'file': filepath,
            'language': 'typescript',
            'classes': classes,
        }

    def _extract_jsdoc(self, lines, line_idx):
        if line_idx == 0:
            return ''
        check_start = max(0, line_idx - 5)
        for i in range(line_idx - 1, check_start - 1, -1):
            line = lines[i].strip()
            if line.startswith('/**'):
                desc_line = lines[i + 1].strip() if i + 1 < line_idx else ''
                if desc_line.startswith('*'):
                    desc_line = desc_line[1:].strip()
                if desc_line and not desc_line.startswith('@') and desc_line != '*/':
                    return desc_line
                return ''
            if not line.startswith('*') and not line.startswith('//') and line:
                break
        return ''

    def extract_imports(self, content, filepath):
        imports = {}
        file_dir = os.path.dirname(filepath)

        for m in self.RE_IMPORT_DESTRUCT.finditer(content):
            names_str = m.group(1)
            source = m.group(2)
            for name in names_str.split(','):
                name = name.strip().split(' as ')[0].strip()
                if name:
                    resolved = self._resolve_import_path(source, file_dir)
                    imports[name] = resolved

        for m in self.RE_IMPORT_DEFAULT.finditer(content):
            name = m.group(1)
            source = m.group(2)
            resolved = self._resolve_import_path(source, file_dir)
            imports[name] = resolved

        for m in self.RE_IMPORT_STAR.finditer(content):
            name = m.group(1)
            source = m.group(2)
            resolved = self._resolve_import_path(source, file_dir)
            imports[name] = resolved

        return imports

    def _resolve_import_path(self, source, file_dir):
        if not source.startswith('.'):
            return f'external:{source}'
        base = os.path.normpath(os.path.join(file_dir, source))
        for ext in ('.ts', '.tsx', '.js', '.jsx', '.d.ts', '/index.ts', '/index.tsx', '/index.js'):
            candidate = base + ext
            if not candidate.startswith('external:'):
                return candidate
        return base + '.ts'

    def extract_calls(self, content, filepath, import_map, known_methods):
        methods_info = self._build_method_map(content)
        func_ranges = self._build_func_ranges(content)
        lines = content.split('\n')
        calls = []

        for func_name, (start_line, end_line, class_name) in func_ranges.items():
            caller = f"{class_name}.{func_name}" if class_name else func_name
            for line_idx in range(start_line, end_line):
                line = lines[line_idx]
                stripped = line.strip()
                if stripped.startswith('//') or stripped.startswith('/*') or stripped.startswith('*'):
                    continue

                for m in self.RE_CALL.finditer(line):
                    callee_str = m.group(1)
                    if callee_str in self.CONTROL_KEYWORDS:
                        continue
                    if callee_str in self.SKIP_CALL_PATTERNS:
                        continue

                    confidence = 'low'
                    callee_file = None

                    if callee_str.startswith('this.'):
                        method = callee_str[5:]
                        if class_name and class_name in methods_info and method in methods_info[class_name]:
                            confidence = 'high'
                            callee_file = filepath
                    elif '.' in callee_str:
                        parts = callee_str.split('.')
                        prefix = parts[0]
                        if prefix in import_map:
                            src = import_map[prefix]
                            if not src.startswith('external:'):
                                callee_file = src
                                confidence = 'high'
                    else:
                        all_methods = set(methods_info.get('module_level', {}).keys())
                        for cls_methods in methods_info.values():
                            if isinstance(cls_methods, dict):
                                all_methods.update(cls_methods.keys())
                        if callee_str in all_methods:
                            confidence = 'high'
                            callee_file = filepath
                        elif callee_str in import_map:
                            src = import_map[callee_str]
                            if not src.startswith('external:'):
                                callee_file = src
                                confidence = 'high'

                    calls.append({
                        'caller': caller,
                        'caller_line': line_idx + 1,
                        'callee': callee_str,
                        'callee_file': callee_file,
                        'confidence': confidence,
                    })

        return calls

    def _build_method_map(self, content):
        methods_info = {}
        lines = content.split('\n')
        current_class = None

        for line_idx, line in enumerate(lines):
            stripped = line.strip()
            if stripped.startswith('//'):
                continue

            cls_m = self.RE_CLASS.search(stripped)
            if cls_m:
                current_class = cls_m.group(1)
                if current_class not in methods_info:
                    methods_info[current_class] = {}
                continue

            func_m = self.RE_FUNC.search(stripped)
            if func_m:
                current_class = None
                if 'module_level' not in methods_info:
                    methods_info['module_level'] = {}
                methods_info['module_level'][func_m.group(1)] = line_idx
                continue

            arrow_m = self.RE_ARROW.search(stripped)
            if arrow_m:
                current_class = None
                if 'module_level' not in methods_info:
                    methods_info['module_level'] = {}
                methods_info['module_level'][arrow_m.group(1)] = line_idx
                continue

            if current_class:
                method_m = self.RE_METHOD.search(stripped)
                if method_m and method_m.group(1) not in self.CONTROL_KEYWORDS:
                    methods_info[current_class][method_m.group(1)] = line_idx

        return methods_info

    def _build_func_ranges(self, content):
        func_ranges = {}
        lines = content.split('\n')
        current_class = None
        func_stack = []

        for line_idx, line in enumerate(lines):
            stripped = line.strip()
            if stripped.startswith('//'):
                continue

            cls_m = self.RE_CLASS.search(stripped)
            if cls_m:
                current_class = cls_m.group(1)
                continue

            func_m = self.RE_FUNC.search(stripped)
            arrow_m = self.RE_ARROW.search(stripped)
            method_m = None
            if current_class:
                method_m = self.RE_METHOD.search(stripped)
                if method_m and method_m.group(1) in self.CONTROL_KEYWORDS:
                    method_m = None

            matched = func_m or arrow_m or method_m
            if matched:
                name = matched.group(1)

                while func_stack:
                    prev_name, prev_start, prev_class, prev_open = func_stack[-1]
                    if self._is_function_closed(lines, prev_start, line_idx):
                        func_stack.pop()
                        func_ranges[f"{prev_class}.{prev_name}" if prev_class else prev_name] = (
                            prev_start, line_idx, prev_class
                        )
                    else:
                        break

                owner = current_class if method_m else None
                func_stack.append((name, line_idx, owner, stripped.count('{') - stripped.count('}')))

        for name, start, owner, _ in func_stack:
            func_ranges[f"{owner}.{name}" if owner else name] = (start, len(lines), owner)

        return func_ranges

    def _is_function_closed(self, lines, start_line, current_line):
        depth = 0
        for i in range(start_line, min(current_line + 1, len(lines))):
            line = lines[i]
            stripped = line.strip()
            if stripped.startswith('//'):
                continue
            for ch in line:
                if ch == '{':
                    depth += 1
                elif ch == '}':
                    depth -= 1
        return depth <= 0

    def detect_entries(self, content, filepath):
        entries = []
        lines = content.split('\n')

        dir_path = os.path.dirname(filepath)
        basename = os.path.basename(filepath)
        if '/pages/api/' in filepath.replace(os.sep, '/') or '/app/api/' in filepath.replace(os.sep, '/'):
            route = '/' + basename.replace('.ts', '').replace('.js', '')
            entries.append({
                'id': route,
                'type': 'api',
                'framework': 'nextjs',
                'file': filepath,
                'line': 1,
                'handler': 'default',
            })

        for m in self.RE_ENTRY_EXPRESS.finditer(content):
            line_no = content[:m.start()].count('\n') + 1
            method = m.group(1).upper()
            route = m.group(2)
            handler = self._find_handler_below(lines, line_no - 1)
            entries.append({
                'id': f"{method} {route}",
                'type': 'api',
                'framework': 'express',
                'file': filepath,
                'line': line_no,
                'handler': handler,
            })

        for m in self.RE_ENTRY_NESTJS.finditer(content):
            line_no = content[:m.start()].count('\n') + 1
            decorator = m.group(1)
            route = m.group(2) if m.group(2) else ''
            method = decorator.upper() if decorator != 'Controller' else ''
            handler = self._find_handler_below(lines, line_no - 1)
            entry_id = f"{method} {route}".strip() if method else route or handler
            entries.append({
                'id': entry_id,
                'type': 'api',
                'framework': 'nestjs',
                'file': filepath,
                'line': line_no,
                'handler': handler,
            })

        return entries

    def _find_handler_below(self, lines, decorator_line):
        for i in range(decorator_line + 1, min(decorator_line + 5, len(lines))):
            line = lines[i].strip()
            if line.startswith('@'):
                continue
            func_m = self.RE_FUNC.search(line)
            if func_m:
                return func_m.group(1)
            arrow_m = self.RE_ARROW.search(line)
            if arrow_m:
                return arrow_m.group(1)
            method_m = self.RE_METHOD.search(line)
            if method_m and method_m.group(1) not in self.CONTROL_KEYWORDS:
                return method_m.group(1)
            if line and not line.startswith('@') and not line.startswith('//'):
                break
        return ''
