import re

from .base import BaseParser


class JavaParser(BaseParser):

    SKIP_CALL_PATTERNS = {
        'System', 'String', 'Integer', 'Long', 'Double', 'Float', 'Boolean',
        'List', 'Map', 'Set', 'Objects', 'Collections', 'Arrays',
        'Math', 'Thread', 'Class', 'Optional',
    }

    RE_METHOD = re.compile(
        r'(?:public|private|protected)\s+'
        r'(?:static\s+)?'
        r'(?:final\s+)?'
        r'(?:synchronized\s+)?'
        r'(?:[\w<>?,\s\[\]]+)\s+'
        r'(\w+)\s*\(([^)]*)\)'
    )
    RE_CONSTRUCTOR = re.compile(
        r'(?:public|private|protected)\s+'
        r'(?:static\s+)?'
        r'(\w+)\s*\(([^)]*)\)\s*(?:throws\s+[\w,\s]+)?\s*\{'
    )
    RE_CLASS = re.compile(r'(?:public|private|protected)?\s*(?:abstract\s+|final\s+)?(?:class|interface|enum)\s+(\w+)')
    RE_IMPORT = re.compile(r'^import\s+([\w.]+)\s*;', re.MULTILINE)

    RE_ENTRY_SPRING = re.compile(r'@(?:Get|Post|Put|Delete|Patch|Request)Mapping\s*\(\s*(?:value\s*=\s*)?[\'"]([^\'"]*)[\'"]')
    RE_ENTRY_SPRING_CLASS = re.compile(r'@(?:Rest)?Controller')

    RE_CALL = re.compile(r'(\w+(?:\.\w+)*)\s*\(')

    def extract_methods(self, content, filepath):
        lines = content.split('\n')
        classes = []
        current_class = None
        class_methods = []

        for line_idx, line in enumerate(lines):
            stripped = line.strip()

            cls_m = self.RE_CLASS.search(stripped)
            if cls_m:
                if current_class and class_methods:
                    classes.append({'name': current_class, 'methods': class_methods})
                current_class = cls_m.group(1)
                class_methods = []
                continue

            if current_class:
                method_m = self.RE_METHOD.search(stripped)
                if method_m and method_m.group(1) != current_class:
                    docstring = self._extract_javadoc(lines, line_idx)
                    class_methods.append({
                        'name': method_m.group(1),
                        'signature': stripped.rstrip('{').strip(),
                        'line': line_idx + 1,
                        'docstring': docstring,
                    })
                    continue

                ctor_m = self.RE_CONSTRUCTOR.search(stripped)
                if ctor_m and ctor_m.group(1) == current_class:
                    docstring = self._extract_javadoc(lines, line_idx)
                    class_methods.append({
                        'name': ctor_m.group(1),
                        'signature': stripped.rstrip('{').strip(),
                        'line': line_idx + 1,
                        'docstring': docstring,
                    })

        if current_class and class_methods:
            classes.append({'name': current_class, 'methods': class_methods})

        return {
            'file': filepath,
            'language': 'java',
            'classes': classes,
        }

    def _extract_javadoc(self, lines, line_idx):
        if line_idx == 0:
            return ''
        for i in range(line_idx - 1, max(0, line_idx - 10) - 1, -1):
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
        for m in self.RE_IMPORT.finditer(content):
            full_name = m.group(1)
            short_name = full_name.split('.')[-1]
            parts = full_name.split('.')
            source = '/'.join(parts[:-1]) + '/' + parts[-1] + '.java'
            imports[short_name] = source
        return imports

    def extract_calls(self, content, filepath, import_map, known_methods):
        lines = content.split('\n')
        func_ranges = self._build_func_ranges(content)
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
                    callee_line = line_idx + 1

                    if callee_str in self.SKIP_CALL_PATTERNS:
                        continue
                    if callee_str == 'return' or callee_str == 'new' or callee_str == 'throw':
                        continue

                    confidence = 'low'
                    callee_file = None

                    if callee_str.startswith('this.'):
                        method = callee_str[5:]
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

            if current_class:
                method_m = self.RE_METHOD.search(stripped)
                ctor_m = self.RE_CONSTRUCTOR.search(stripped)

                matched = None
                name = None
                if method_m and method_m.group(1) != current_class:
                    matched = method_m
                    name = method_m.group(1)
                elif ctor_m and ctor_m.group(1) == current_class:
                    matched = ctor_m
                    name = ctor_m.group(1)

                if matched and name:
                    while func_stack:
                        prev_name, prev_start, prev_class, prev_depth = func_stack[-1]
                        if self._is_block_closed(lines, prev_start, line_idx):
                            func_stack.pop()
                            func_ranges[f"{prev_class}.{prev_name}"] = (prev_start, line_idx, prev_class)
                        else:
                            break
                    func_stack.append((name, line_idx, current_class, 0))

        for name, start, cls, _ in func_stack:
            func_ranges[f"{cls}.{name}"] = (start, len(lines), cls)

        return func_ranges

    def _is_block_closed(self, lines, start_line, current_line):
        depth = 0
        for i in range(start_line, min(current_line + 1, len(lines))):
            for ch in lines[i]:
                if ch == '{':
                    depth += 1
                elif ch == '}':
                    depth -= 1
        return depth <= 0

    def detect_entries(self, content, filepath):
        entries = []
        lines = content.split('\n')

        current_class = None
        is_controller = False

        for line_idx, line in enumerate(lines):
            stripped = line.strip()

            if self.RE_ENTRY_SPRING_CLASS.search(stripped):
                is_controller = True
                cls_m = self.RE_CLASS.search(lines[line_idx + 1] if line_idx + 1 < len(lines) else '')
                if cls_m:
                    current_class = cls_m.group(1)
                continue

            if is_controller:
                entry_m = self.RE_ENTRY_SPRING.search(stripped)
                if entry_m:
                    route = entry_m.group(1)
                    mapping_type = ''
                    for kw in ('GetMapping', 'PostMapping', 'PutMapping', 'DeleteMapping', 'PatchMapping', 'RequestMapping'):
                        if kw in stripped:
                            mapping_type = kw.replace('Mapping', '').upper()
                            if mapping_type == 'REQUEST':
                                mapping_type = ''
                            break
                    handler = ''
                    method_m = self.RE_METHOD.search(stripped)
                    if method_m:
                        handler = method_m.group(1)

                    entry_id = f"{mapping_type} {route}".strip() if mapping_type else route
                    entries.append({
                        'id': entry_id,
                        'type': 'api',
                        'framework': 'spring',
                        'file': filepath,
                        'line': line_idx + 1,
                        'handler': handler,
                    })

        return entries
