// Copyright (c) 2026 PlayGTA5. BSD-3-Clause; see LICENSE.
#include "torrent_path.h"
#include <iostream>
#include <stdexcept>
int main() {
  auto require=[](bool valid) { if(!valid) throw std::runtime_error("torrent path regression"); };
  require(te::portable_path("fixture\\a.bin", true)=="fixture/a.bin");
  require(te::safe_path(te::portable_path("fixture\\a.bin", true)));
  for (auto path: {"..\\escape", "fixture\\..\\escape", "C:\\escape", "\\\\host\\share", "fixture/../escape"})
    require(!te::safe_path(te::portable_path(path, true)));
  require(!te::safe_path(te::portable_path("fixture\\a.bin", false)));
  require(te::safe_path("fixture/a.bin"));
  std::cout << "Portable torrent paths preserve traversal rejection\n";
}
