import re
import os

from .base import BaseParser


class GoParser(BaseParser):

    SKIP_CALL_PATTERNS = {
        'fmt', 'log', 'errors', 'strings', 'strconv', 'json', 'os',
        'io', 'path', 'filepath', 'http', 'context', 'time', 'sync',
        'reflect', 'unsafe', 'builtin',
    }

    RE_FUNC = re.compile(r'^func\s+(\w+)\s*\(([^)]*)\)', re.MULTILINE)
    RE_METHOD = re.compile(r'^func\s+\(\s*(\w+)\s+\*?(\w+)\s*\)\s+(\w+)\s*\(([^)]*)\)', re.MULTILINE)
    RE_IMPORT_SINGLE = re.compile(r'^import\s+"([^"]+)"', re.MULTILINE)
    RE_IMPORT_MULTI = re.compile(r'import\s*\((.*?)\)', re.DOTALL)
    RE_IMPORT_LINE = re.compile(r'"([^"]+)"')

    RE_ENTRY_HTTP = re.compile(r'(?:http\.HandleFunc|http\.Handle|mux\.(?:HandleFunc|Handle|Get|Post|Put|Delete|PathPrefix))\s*\(\s*"([^"]*)"')
    RE_ENTRY_GIN = re.compile(r'(?:r|router|engine|e)\.(?:GET|POST|PUT|DELETE|PATCH)\s*\(\s*"([^"]*)"')
    RE_ENTRY_ECHO = re.compile(r'e\.(?:GET|POST|PUT|DELETE|PATCH)\s*\(\s*"([^"]*)"')
    RE_ENTRY_FIBER = re.compile(r'app\.(?:Get|Post|Put|Delete|Patch|Use)\s*\(\s*"([^"]*)"')
    RE_ENTRY_CMD = re.compile(r'(?:cmd|rootCmd)\.?(?:AddCommand|RunE|Run)\s*\(')

    RE_CALL = re.compile(r'(\w+(?:\.\w+)*)\s*\(')

    def extract_methods(self, content, filepath):
        classes = []

        receiver_methods = {}
        for m in self.RE_METHOD.finditer(content):
            receiver_type = m.group(2)
            method_name = m.group(3)
            line_no = content[:m.start()].count('\n') + 1
            params = m.group(4)

            docstring = self._extract_comment(content, m.start())

            if receiver_type not in receiver_methods:
                receiver_methods[receiver_type] = []
            receiver_methods[receiver_type].append({
                'name': method_name,
                'signature': f"func ({m.group(1)} *{receiver_type}) {method_name}({params})",
                'line': line_no,
                'docstring': docstring,
            })

        for type_name, methods in receiver_methods.items():
            classes.append({'name': type_name, 'methods': methods})

        module_methods = []
        for m in self.RE_FUNC.finditer(content):
            func_name = m.group(1)
            is_method = False
            for m2 in self.RE_METHOD.finditer(content):
                if m2.start() == m.start():
                    is_method = True
                    break

            if is_method:
                continue

            line_no = content[:m.start()].count('\n') + 1
            params = m.group(2)
            docstring = self._extract_comment(content, m.start())

            module_methods.append({
                'name': func_name,
                'signature': f"func {func_name}({params})",
                'line': line_no,
                'docstring': docstring,
            })

        if module_methods:
            classes.append({'name': 'module_level', 'methods': module_methods})

        return {
            'file': filepath,
            'language': 'go',
            'classes': classes,
        }

    def _extract_comment(self, content, pos):
        lines_before = content[:pos].split('\n')
        for i in range(len(lines_before) - 1, max(0, len(lines_before) - 5) - 1, -1):
            line = lines_before[i].strip()
            if line.startswith('//'):
                desc = line.lstrip('/').strip()
                if desc:
                    return desc
            elif line == '':
                continue
            else:
                break
        return ''

    def extract_imports(self, content, filepath):
        imports = {}

        for m in self.RE_IMPORT_SINGLE.finditer(content):
            pkg = m.group(1)
            name = pkg.split('/')[-1]
            imports[name] = f'external:{pkg}'

        multi_m = self.RE_IMPORT_MULTI.search(content)
        if multi_m:
            for m in self.RE_IMPORT_LINE.finditer(multi_m.group(1)):
                pkg = m.group(1)
                if not pkg.startswith('.') and not pkg.startswith('/'):
                    name = pkg.split('/')[-1]
                    imports[name] = f'external:{pkg}'
                else:
                    name = pkg.split('/')[-1]
                    imports[name] = pkg

        return imports

    def extract_calls(self, content, filepath, import_map, known_methods):
        lines = content.split('\n')
        func_ranges = self._build_func_ranges(content)
        calls = []

        for func_name, (start_line, end_line, receiver_type) in func_ranges.items():
            caller = f"{receiver_type}.{func_name}" if receiver_type else func_name
            for line_idx in range(start_line, end_line):
                line = lines[line_idx]
                stripped = line.strip()
                if stripped.startswith('//'):
                    continue

                for m in self.RE_CALL.finditer(line):
                    callee_str = m.group(1)
                    callee_line = line_idx + 1

                    if callee_str in self.SKIP_CALL_PATTERNS:
                        continue
                    if callee_str in ('func', 'return', 'defer', 'go', 'make', 'new', 'len', 'cap',
                                      'append', 'copy', 'delete', 'close', 'panic', 'recover',
                                      'println', 'print'):
                        continue

                    confidence = 'low'
                    callee_file = None

                    if '.' in callee_str:
                        parts = callee_str.split('.')
                        prefix = parts[0]
                        if prefix in import_map:
                            src = import_map[prefix]
                            if not src.startswith('external:'):
                                callee_file = src
                                confidence = 'high'
                    else:
                        if callee_str in import_map:
                            src = import_map[callee_str]
                            if not src.startswith('external:'):
                                callee_file = src
                                confidence = 'high'

                    calls.append({
                        'caller': caller,
                        'caller_line': callee_line,
                        'callee': callee_str,
                        'callee_file': callee_file,
                        'confidence': confidence,
                    })

        return calls

    def _build_func_ranges(self, content):
        func_ranges = {}
        lines = content.split('\n')
        func_entries = []

        for m in self.RE_METHOD.finditer(content):
            line_no = content[:m.start()].count('\n')
            func_name = m.group(3)
            receiver_type = m.group(2)
            func_entries.append((func_name, line_no, receiver_type))

        for m in self.RE_FUNC.finditer(content):
            is_method = False
            for m2 in self.RE_METHOD.finditer(content):
                if m2.start() == m.start():
                    is_method = True
                    break
            if not is_method:
                line_no = content[:m.start()].count('\n')
                func_name = m.group(1)
                func_entries.append((func_name, line_no, None))

        func_entries.sort(key=lambda x: x[1])

        for i, (name, start, rtype) in enumerate(func_entries):
            end = len(lines)
            if i + 1 < len(func_entries):
                end = func_entries[i + 1][1]
            func_ranges[f"{rtype}.{name}" if rtype else name] = (start, end, rtype)

        return func_ranges

    def detect_entries(self, content, filepath):
        entries = []
        lines = content.split('\n')

        all_patterns = [
            (self.RE_ENTRY_HTTP, 'api', 'net/http'),
            (self.RE_ENTRY_GIN, 'api', 'gin'),
            (self.RE_ENTRY_ECHO, 'api', 'echo'),
            (self.RE_ENTRY_FIBER, 'api', 'fiber'),
            (self.RE_ENTRY_CMD, 'cli', 'cobra'),
        ]

        for pattern, entry_type, framework in all_patterns:
            for m in pattern.finditer(content):
                line_no = content[:m.start()].count('\n') + 1
                route = m.group(1) if m.group(1) else ''
                handler = self._find_handler_on_line(lines, line_no - 1)

                if entry_type == 'api' and route:
                    method = ''
                    for kw in ('GET', 'POST', 'PUT', 'DELETE', 'PATCH'):
                        if kw in lines[line_no - 1].upper():
                            method = kw
                            break
                    entry_id = f"{method} {route}" if method else route
                elif handler:
                    entry_id = handler
                else:
                    entry_id = f"{entry_type}:{filepath}:{line_no}"

                entries.append({
                    'id': entry_id,
                    'type': entry_type,
                    'framework': framework,
                    'file': filepath,
                    'line': line_no,
                    'handler': handler,
                })

        return entries

    def _find_handler_on_line(self, lines, line_idx):
        if line_idx >= len(lines):
            return ''
        func_m = self.RE_FUNC.search(lines[line_idx])
        if func_m:
            return func_m.group(1)
        for i in range(line_idx + 1, min(line_idx + 5, len(lines))):
            func_m = self.RE_FUNC.search(lines[i])
            if func_m:
                return func_m.group(1)
        return ''
