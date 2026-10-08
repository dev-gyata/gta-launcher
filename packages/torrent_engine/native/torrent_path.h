// Copyright (c) 2026 PlayGTA5. BSD-3-Clause; see LICENSE.
#pragma once
#include <algorithm>
#include <filesystem>
#include <string>
namespace te {
inline std::string portable_path(std::string name, bool windows_separators) {
  if (windows_separators) std::replace(name.begin(), name.end(), '\\', '/');
  return name;
}
inline bool safe_path(std::string const& name) {
  if (name.empty() || name.find('\\') != std::string::npos || name.find(':') != std::string::npos) return false;
  auto p = std::filesystem::u8path(name);
  if (p.is_absolute()) return false;
  for (auto const& part : p) if (part == "." || part == ".." || part.empty()) return false;
  return true;
}
}
