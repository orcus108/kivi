"""Register Kivi Swift sources, retaining Xcode IDs when files move folders."""
from pathlib import Path
import hashlib
import re


def register(root: Path) -> None:
    project = root / 'foundation/TypeWhisper.xcodeproj/project.pbxproj'
    files = sorted((root / 'foundation/TypeWhisper/KiviUI').rglob('*.swift'))
    names = [file.name for file in files]
    if len(names) != len(set(names)):
        raise ValueError('Kivi Swift filenames must be unique to retain stable Xcode IDs')

    text = project.read_text()
    file_marker = '/* Begin PBXFileReference section */'
    build_marker = '/* Begin PBXBuildFile section */'
    sources_marker = 'FF00000000000000000002 /* Sources */ = {'
    for marker in (file_marker, build_marker, sources_marker):
        if marker not in text:
            raise ValueError(f'Missing Xcode project section: {marker}')

    for file in files:
        file_id = hashlib.sha1(('kivi-file-' + file.name).encode()).hexdigest()[:24].upper()
        build_id = hashlib.sha1(('kivi-build-' + file.name).encode()).hexdigest()[:24].upper()
        relative = file.relative_to(root / 'foundation').as_posix()
        reference = (f'{file_id} /* {file.name} */ = {{isa = PBXFileReference; '
                     f'lastKnownFileType = sourcecode.swift; path = {relative}; sourceTree = SOURCE_ROOT; }};')
        pattern = re.escape(file_id) + r' /\*[^\n]*?\*/ = \{isa = PBXFileReference;[^\n]*?\};'
        if re.search(pattern, text):
            text = re.sub(pattern, lambda _: reference, text)
            continue
        if file_id in text:
            raise ValueError(f'Unrecognized file reference for {file.name}')
        text = text.replace(file_marker, file_marker + '\n\t\t' + reference, 1)
        text = text.replace(build_marker, build_marker + '\n\t\t' +
                            f'{build_id} /* {file.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id} /* {file.name} */; }};', 1)
        start = text.index('files = (', text.index(sources_marker)) + len('files = (')
        text = text[:start] + f'\n\t\t\t\t{build_id} /* {file.name} in Sources */,' + text[start:]

    if text != project.read_text():
        project.write_text(text)


if __name__ == '__main__':
    register(Path(__file__).resolve().parents[1])
