from pathlib import Path

from .python import PythonParser
from .typescript import TypeScriptParser
from .java import JavaParser
from .golang import GoParser

LANGUAGE_MAP = {
    '.py': PythonParser,
    '.ts': TypeScriptParser,
    '.tsx': TypeScriptParser,
    '.js': TypeScriptParser,
    '.jsx': TypeScriptParser,
    '.java': JavaParser,
    '.go': GoParser,
}

_parsers = {}


def get_parser(filepath):
    ext = Path(filepath).suffix
    cls = LANGUAGE_MAP.get(ext)
    if cls is None:
        return None
    if cls not in _parsers:
        _parsers[cls] = cls()
    return _parsers[cls]
