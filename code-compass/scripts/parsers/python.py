import re
import os

from .base import BaseParser


class PythonParser(BaseParser):

    SKIP_CALL_PATTERNS = {
        'super', 'print', 'len', 'range', 'isinstance', 'type', 'str', 'int',
        'float', 'list', 'dict', 'set', 'tuple', 'bool', 'bytes', 'open',
        'getattr', 'setattr', 'hasattr', 'issubclass', 'property',
        'staticmethod', 'classmethod', 'enumerate', 'zip', 'map', 'filter',
        'sorted', 'reversed', 'any', 'all', 'min', 'max', 'sum', 'abs',
        'round', 'repr', 'format', 'hash', 'id', 'dir', 'vars', 'callable',
        '__import__', 'breakpoint',
    }

    RE_DEF = re.compile(r'^(\s*)(?:async\s+)?def\s+(\w+)\s*\(([^)]*)\)', re.MULTILINE)
    RE_CLASS = re.compile(r'^(\s*)class\s+(\w+)[\s:(]', re.MULTILINE)
    RE_IMPORT_FROM = re.compile(r'^from\s+([\w.]+)\s+import\s+(.+)$', re.MULTILINE)
    RE_IMPORT_BARE = re.compile(r'^import\s+([\w.]+)(?:\s+as\s+(\w+))?$', re.MULTILINE)
    RE_DECORATOR = re.compile(r'^\s*@', re.MULTILINE)

    RE_ENTRY_FASTAPI = re.compile(r'@(?:app|router)\.(get|post|put|delete|patch)\s*\(\s*[\'"]([^\'"]*)[\'"]')
    RE_ENTRY_FLASK = re.compile(r'@(?:app|bp)\.route\s*\(\s*[\'"]([^\'"]*)[\'"]')
    RE_ENTRY_DJANGO = re.compile(r'(?:url|path|re_path)\s*\(\s*[\'"]([^\'"]*)[\'"]')

    RE_ENTRY_CELERY = re.compile(r'@(?:app\.task|shared_task|celery\.task)')
    RE_ENTRY_SCHEDULER = re.compile(r'@(?:scheduler\.scheduled_job|periodic_task|cron|schedule|periodic)')

    RE_ENTRY_CLICK = re.compile(r'@(?:click\.(?:command|group))\s*\(')
    RE_ENTRY_TYPER = re.compile(r'@app\.(?:command|callback)')

    RE_DOCSTRING_TRIPLE = re.compile(r'^(\s*)(?:"""|\'\'\')\s*(.*?)\s*(?:"""|\'\'\')?$', re.DOTALL)
    RE_DOCSTRING_OPEN = re.compile(r'^(\s*)(?:"""|\'\'\')\s*(.*?)$', re.MULTILINE)

    RE_CALL = re.compile(r'(\w+(?:\.\w+)*)\s*\(')
    RE_SELF_CALL = re.compile(r'self\.(\w+)\s*\(')
    RE_CLS_CALL = re.compile(r'cls\.(\w+)\s*\(')
    RE_SUPER_CALL = re.compile(r'super\(\)')
    RE_GETATTR = re.compile(r'getattr\s*\(')
    RE_CHAIN_CALL = re.compile(r'(\w+(?:\.\w+){2,})\s*\(')

    def extract_methods(self, content, filepath):
        lines = content.split('\n')
        classes = []
        current_class = None
        current_class_indent = -1

        class_ranges = []
        for m in self.RE_CLASS.finditer(content):
            indent = len(m.group(1))
            class_ranges.append((m.start(), m.group(2), indent, m.end()))

        def_lines = []
        for m in self.RE_DEF.finditer(content):
            def_lines.append((m.start(), m.end(), m.group(1), m.group(2), m.group(3)))

        line_starts = []
        pos = 0
        for i, line in enumerate(lines):
            line_starts.append(pos)
            pos += len(line) + 1

        def pos_to_line(target_pos):
            lo, hi = 0, len(line_starts) - 1
            while lo <= hi:
                mid = (lo + hi) // 2
                if line_starts[mid] <= target_pos:
                    lo = mid + 1
                else:
                    hi = mid - 1
            return hi + 1

        def find_class_for(def_pos, def_indent_len):
            result = None
            for cls_start, cls_name, cls_indent, cls_end in class_ranges:
                if cls_start < def_pos and def_indent_len > cls_indent:
                    result = cls_name
                elif cls_start >= def_pos:
                    break
            return result

        result_classes = {}

        for def_start, def_end, indent_str, func_name, params in def_lines:
            indent_len = len(indent_str)
            cls_name = find_class_for(def_start, indent_len)
            line_no = pos_to_line(def_start)

            signature = f"{'async ' if 'async ' in content[max(0, def_start - 10):def_start] else ''}def {func_name}({params})"

            docstring = self._extract_docstring(lines, line_no - 1)

            entry = {
                'name': func_name,
                'signature': signature.strip(),
                'line': line_no,
                'docstring': docstring,
            }

            key = cls_name if cls_name else 'module_level'
            if key not in result_classes:
                result_classes[key] = {'name': key, 'methods': []}
            result_classes[key]['methods'].append(entry)

        classes_list = list(result_classes.values())
        if 'module_level' in result_classes:
            mod = result_classes['module_level']
            classes_list.remove(mod)
            classes_list.append(mod)

        return {
            'file': filepath,
            'language': 'python',
            'classes': classes_list,
        }

    def _extract_docstring(self, lines, def_line_idx):
        body_start = def_line_idx + 1
        if body_start >= len(lines):
            return ''

        first_body = lines[body_start].strip()
        if not first_body:
            if body_start + 1 < len(lines):
                first_body = lines[body_start + 1].strip()
            else:
                return ''

        if first_body.startswith('"""') or first_body.startswith("'''"):
            quote = first_body[:3]
            rest = first_body[3:]
            if rest.endswith(quote) and len(rest) > 0:
                return rest[:-3].strip().split('\n')[0]
            if rest.strip():
                return rest.strip().split('\n')[0]
            for i in range(body_start + 1, min(body_start + 5, len(lines))):
                line = lines[i].strip()
                if line.endswith(quote):
                    return line[:-3].strip() if line != quote else ''
                if line:
                    return line.strip()
        return ''

    def extract_imports(self, content, filepath):
        imports = {}

        for m in self.RE_IMPORT_FROM.finditer(content):
            module = m.group(1)
            names_str = m.group(2)
            for name in names_str.split(','):
                name = name.strip().split(' as ')[0].strip()
                if name:
                    source = module.replace('.', os.sep) + '.py'
                    imports[name] = source

        for m in self.RE_IMPORT_BARE.finditer(content):
            module = m.group(1)
            alias = m.group(2)
            name = alias if alias else module.split('.')[-1]
            source = module.replace('.', os.sep) + '.py'
            imports[name] = source

        return imports

    def extract_calls(self, content, filepath, import_map, known_methods):
        lines = content.split('\n')

        methods_info = self._build_method_map(content)

        func_ranges = self._build_func_ranges(content)

        calls = []

        for func_name, (start_line, end_line, class_name) in func_ranges.items():
            caller = f"{class_name}.{func_name}" if class_name else func_name

            for line_idx in range(start_line, end_line):
                line = lines[line_idx]

                for m in self.RE_CALL.finditer(line):
                    callee_str = m.group(1)
                    callee_line = line_idx + 1

                    if self._should_skip(callee_str, line):
                        continue

                    confidence = 'low'
                    callee_file = None

                    if callee_str.startswith('self.'):
                        method = callee_str[5:]
                        if class_name and class_name in methods_info and method in methods_info[class_name]:
                            confidence = 'high'
                            callee_file = filepath
                    elif callee_str.startswith('cls.'):
                        method = callee_str[4:]
                        if class_name and class_name in methods_info and method in methods_info[class_name]:
                            confidence = 'high'
                            callee_file = filepath
                    elif '.' in callee_str:
                        parts = callee_str.split('.')
                        prefix = parts[0]
                        if prefix in import_map:
                            callee_file = import_map[prefix]
                            confidence = 'high'
                    else:
                        if callee_str in methods_info.get('module_level', {}):
                            confidence = 'high'
                            callee_file = filepath
                        elif callee_str in import_map:
                            callee_file = import_map[callee_str]
                            confidence = 'high'

                    calls.append({
                        'caller': caller,
                        'caller_line': callee_line,
                        'callee': callee_str,
                        'callee_file': callee_file,
                        'confidence': confidence,
                    })

        return calls

    def _should_skip(self, callee_str, line):
        if self.RE_SUPER_CALL.search(line) and 'super()' in callee_str:
            return True
        if self.RE_GETATTR.search(line):
            return True
        if callee_str in self.SKIP_CALL_PATTERNS:
            return True
        stripped = line.strip()
        if stripped.startswith('@') or stripped.startswith('#'):
            return True
        return False

    def _build_method_map(self, content):
        methods_info = {}
        lines = content.split('\n')

        class_ranges = []
        for m in self.RE_CLASS.finditer(content):
            indent = len(m.group(1))
            class_ranges.append((m.group(2), indent))

        def_entries = []
        for m in self.RE_DEF.finditer(content):
            indent = len(m.group(1))
            func_name = m.group(2)
            line_no = content[:m.start()].count('\n')
            def_entries.append((func_name, indent, line_no))

        line_starts = []
        pos = 0
        for line in lines:
            line_starts.append(pos)
            pos += len(line) + 1

        for func_name, def_indent, def_line in def_entries:
            owner = 'module_level'
            for cls_name, cls_indent in class_ranges:
                if def_indent > cls_indent:
                    owner = cls_name
                else:
                    break

            if owner not in methods_info:
                methods_info[owner] = {}
            methods_info[owner][func_name] = def_line

        return methods_info

    def _build_func_ranges(self, content):
        lines = content.split('\n')
        func_ranges = {}

        class_ranges = []
        for m in self.RE_CLASS.finditer(content):
            indent = len(m.group(1))
            line_no = content[:m.start()].count('\n')
            class_ranges.append((line_no, indent, m.group(2)))

        def_entries = []
        for m in self.RE_DEF.finditer(content):
            indent = len(m.group(1))
            func_name = m.group(2)
            line_no = content[:m.start()].count('\n')
            def_entries.append((func_name, indent, line_no))

        for i, (func_name, def_indent, def_line) in enumerate(def_entries):
            end_line = len(lines)
            for j in range(i + 1, len(def_entries)):
                _, next_indent, next_line = def_entries[j]
                if next_indent <= def_indent:
                    end_line = next_line
                    break

            owner_class = None
            for cls_line, cls_indent, cls_name in class_ranges:
                if cls_line < def_line and def_indent > cls_indent:
                    owner_class = cls_name

            func_ranges[func_name] = (
                def_line, end_line, owner_class
            )

        return func_ranges

    def detect_entries(self, content, filepath):
        entries = []
        lines = content.split('\n')

        api_patterns = [
            (self.RE_ENTRY_FASTAPI, 'api', 'fastapi'),
            (self.RE_ENTRY_FLASK, 'api', 'flask'),
            (self.RE_ENTRY_DJANGO, 'api', 'django'),
        ]

        task_patterns = [
            (self.RE_ENTRY_CELERY, 'task', 'celery'),
            (self.RE_ENTRY_SCHEDULER, 'task', 'generic'),
        ]

        cli_patterns = [
            (self.RE_ENTRY_CLICK, 'cli', 'click'),
            (self.RE_ENTRY_TYPER, 'cli', 'typer'),
        ]

        all_patterns = api_patterns + task_patterns + cli_patterns

        for pattern, entry_type, framework in all_patterns:
            for m in pattern.finditer(content):
                line_no = content[:m.start()].count('\n') + 1
                handler = self._find_handler_below(lines, line_no - 1)
                route = m.group(1) if m.lastindex and m.lastindex >= 1 else ''

                if entry_type == 'api' and route:
                    method = ''
                    if pattern == self.RE_ENTRY_FASTAPI:
                        for g in m.groups():
                            pass
                        method = m.group(1).upper() if m.group(1) else ''
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

    def _find_handler_below(self, lines, decorator_line):
        for i in range(decorator_line + 1, min(decorator_line + 5, len(lines))):
            line = lines[i].strip()
            if line.startswith('@'):
                continue
            m = self.RE_DEF.match(lines[i])
            if m:
                return m.group(2)
            if line and not line.startswith('@') and not line.startswith('#'):
                break
        return ''
