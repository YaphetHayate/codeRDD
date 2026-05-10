from abc import ABC, abstractmethod


class BaseParser(ABC):

    @abstractmethod
    def extract_methods(self, content, filepath):
        pass

    @abstractmethod
    def extract_imports(self, content, filepath):
        pass

    @abstractmethod
    def extract_calls(self, content, filepath, import_map, known_methods):
        pass

    @abstractmethod
    def detect_entries(self, content, filepath):
        pass
