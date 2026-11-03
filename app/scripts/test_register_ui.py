"""Regression checks for recursive, stable Kivi source registration."""
from pathlib import Path
import tempfile
import unittest
from register_ui import register

PROJECT = '''/* Begin PBXBuildFile section */
/* Begin PBXFileReference section */
FF00000000000000000002 /* Sources */ = {
files = (
);
};
'''


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.project = self.root / 'foundation/TypeWhisper.xcodeproj/project.pbxproj'
        self.project.parent.mkdir(parents=True)
        self.project.write_text(PROJECT)
        self.sources = self.root / 'foundation/TypeWhisper/KiviUI'
        self.sources.mkdir(parents=True)

    def source(self, name):
        path = self.sources / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('import SwiftUI\n')
        return path

    def test_nested_sources_are_registered_once(self):
        self.source('Features/ForYou/Conversation.swift')
        register(self.root)
        result = self.project.read_text()
        self.assertIn('path = TypeWhisper/KiviUI/Features/ForYou/Conversation.swift;', result)
        self.assertEqual(result.count('isa = PBXBuildFile;'), 1)
        self.assertEqual(result.count('isa = PBXFileReference;'), 1)
        register(self.root)
        self.assertEqual(self.project.read_text(), result)

    def test_move_preserves_file_and_build_ids(self):
        original = self.source('Conversation.swift')
        register(self.root)
        old = self.project.read_text()
        target = self.sources / 'Features/ForYou/Conversation.swift'
        target.parent.mkdir(parents=True)
        original.rename(target)
        register(self.root)
        self.assertEqual(self.project.read_text(), old.replace('KiviUI/Conversation.swift', 'KiviUI/Features/ForYou/Conversation.swift'))

    def test_duplicate_names_fail_without_partial_write(self):
        self.source('First/Conversation.swift')
        self.source('Second/Conversation.swift')
        with self.assertRaisesRegex(ValueError, 'unique'):
            register(self.root)
        self.assertEqual(self.project.read_text(), PROJECT)

    def test_missing_section_fails_without_partial_write(self):
        self.source('Conversation.swift')
        broken = PROJECT.replace('/* Begin PBXBuildFile section */', '')
        self.project.write_text(broken)
        with self.assertRaisesRegex(ValueError, 'Missing Xcode project section'):
            register(self.root)
        self.assertEqual(self.project.read_text(), broken)


if __name__ == '__main__':
    unittest.main()
