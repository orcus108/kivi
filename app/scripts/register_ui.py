from pathlib import Path
import hashlib,re
root=Path(__file__).resolve().parents[1]
p=root/'foundation/TypeWhisper.xcodeproj/project.pbxproj'
s=p.read_text()
for f in sorted((root/'foundation/TypeWhisper/KiviUI').glob('*.swift')):
 fid=hashlib.sha1(('kivi-file-'+f.name).encode()).hexdigest()[:24].upper(); bid=hashlib.sha1(('kivi-build-'+f.name).encode()).hexdigest()[:24].upper()
 if fid in s: continue
 s=s.replace('/* Begin PBXBuildFile section */',f'/* Begin PBXBuildFile section */\n\t\t{bid} /* {f.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fid} /* {f.name} */; }};')
 s=s.replace('/* Begin PBXFileReference section */',f'/* Begin PBXFileReference section */\n\t\t{fid} /* {f.name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = TypeWhisper/KiviUI/{f.name}; sourceTree = SOURCE_ROOT; }};')
 a=s.index('FF00000000000000000002 /* Sources */ = {'); b=s.index('files = (',a)+len('files = (')
 s=s[:b]+f'\n\t\t\t\t{bid} /* {f.name} in Sources */,'+s[b:]
p.write_text(s)
