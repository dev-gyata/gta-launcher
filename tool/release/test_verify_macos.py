import unittest
from verify_macos import deployment_versions


class DeploymentTargetTests(unittest.TestCase):
    def test_ignores_linker_and_source_versions(self):
        loads = '''Load command 1
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 1
    minos 12.0
      sdk 27.0
   ntools 1
     tool 3
  version 27037.1
Load command 2
      cmd LC_SOURCE_VERSION
  cmdsize 16
  version 42.0
'''
        self.assertEqual(deployment_versions(loads), ['12.0'])

    def test_reads_legacy_and_multiple_archive_members(self):
        loads = '''cmd LC_VERSION_MIN_MACOSX
cmdsize 16
version 11.0
sdk 12.0
cmd LC_BUILD_VERSION
cmdsize 24
platform 1
minos 13.0
sdk 27.0
'''
        self.assertEqual(deployment_versions(loads), ['11.0', '13.0'])


if __name__ == '__main__':
    unittest.main()
