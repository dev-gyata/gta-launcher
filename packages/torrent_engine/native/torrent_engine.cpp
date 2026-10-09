// Copyright (c) 2026 PlayGTA5. BSD-3-Clause; see LICENSE.
#include "torrent_engine.h"
#include "torrent_path.h"
#include <libtorrent/session.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/version.hpp>
#include <filesystem>
#include <fstream>
#include <map>
#include <set>
#include <vector>
#include <memory>
#include <cstring>
#include <chrono>
#include <iostream>
#include <cstdlib>
#ifdef _WIN32
#include <windows.h>
#else
#include <sys/stat.h>
#endif
namespace lt = libtorrent;
namespace fs = std::filesystem;
struct Engine {
  std::unique_ptr<lt::session> session;
  lt::torrent_handle torrent;
  std::shared_ptr<lt::torrent_info const> info;
  std::string error, cache, payload;
  std::vector<std::string> paths;
  std::map<int, std::vector<char>> pieces;
  std::set<int> requested;
  std::set<int> reading;  // requested pieces already on disk, read directly (see te_poll)
};
static Engine& engine(void* p) { return *static_cast<Engine*>(p); }
static void metadata(Engine& e) {
  e.info = e.torrent.torrent_file();
  if (!e.info) return;
  if (e.info->num_files() > 100000 || e.info->num_pieces() > 1000000 || e.info->piece_length() > 16 * 1024 * 1024)
    throw std::runtime_error("Torrent metadata exceeds supported file or piece limits");
  auto const& files = e.info->files();
  e.paths.resize(files.num_files());
  for (auto i : files.file_range()) {
#ifdef _WIN32
    constexpr bool windows_separators = true;
#else
    constexpr bool windows_separators = false;
#endif
    auto name = te::portable_path(files.file_path(i), windows_separators);
    if (!te::safe_path(name) || (files.file_flags(i) & lt::file_storage::flag_symlink))
      throw std::runtime_error("Torrent metadata contains an unsafe file path or symlink");
    auto current = fs::u8path(e.payload);
    for (auto const& part : fs::u8path(name)) {
      current /= part;
      std::error_code ec;
      if (fs::is_symlink(fs::symlink_status(current, ec)))
        throw std::runtime_error("Torrent cache contains a symlink");
    }
    e.paths[int(i)] = (files.file_flags(i) & lt::file_storage::flag_pad_file) ? "" : name;
  }
  e.torrent.prioritize_pieces(std::vector<lt::download_priority_t>(e.info->num_pieces(), lt::dont_download));
}
extern "C" {
int64_t te_disk_usage(char const* path) {
  try {
    auto root = fs::u8path(path);
    if (!fs::exists(root) || fs::is_symlink(fs::symlink_status(root))) return 0;
    int64_t bytes=0;
    for (auto const& entry: fs::recursive_directory_iterator(root)) {
      auto status=entry.symlink_status();
      if (!fs::is_regular_file(status)) continue;
#ifdef _WIN32
      DWORD high=0;
      SetLastError(NO_ERROR);
      DWORD low=GetCompressedFileSizeW(entry.path().c_str(),&high);
      if(low==INVALID_FILE_SIZE && GetLastError()!=NO_ERROR) return -1;
      bytes += int64_t((uint64_t(high)<<32)|low);
#else
      struct stat data;
      if (lstat(entry.path().c_str(),&data)!=0) return -1;
      bytes += int64_t(data.st_blocks)*512;
#endif
    }
    return bytes;
  } catch (...) { return -1; }
}
void* te_open(char const* magnet, char const* cache) {
  auto* e = new Engine;
  try {
    e->cache = cache;
    if (fs::is_symlink(fs::symlink_status(fs::u8path(e->cache)))) throw std::runtime_error("Torrent cache is a symlink");
    fs::create_directories(fs::u8path(e->cache));
    e->payload = (fs::u8path(e->cache) / "payload").u8string();
    if (fs::is_symlink(fs::symlink_status(fs::u8path(e->payload)))) throw std::runtime_error("Torrent payload cache is a symlink");
    fs::create_directories(fs::u8path(e->payload));
    auto resume = fs::u8path(e->cache) / "resume.dat";
    if (fs::is_symlink(fs::symlink_status(resume))) throw std::runtime_error("Torrent resume cache is a symlink");
    if (fs::exists(resume) && fs::file_size(resume) > 64 * 1024 * 1024) throw std::runtime_error("Torrent resume data exceeds 64 MiB");
    lt::error_code ec;
    auto p = lt::parse_magnet_uri(magnet, ec);
    if (ec) throw std::runtime_error("Invalid magnet: " + ec.message());
    auto expected = p.info_hashes;
    auto trackers = p.trackers;
    auto peers = p.peers;
    std::ifstream input(fs::u8path(e->cache) / "resume.dat", std::ios::binary);
    if (input) {
      std::vector<char> bytes((std::istreambuf_iterator<char>(input)), {});
      auto resumed = lt::read_resume_data(bytes, ec);
      bool const matching = (!expected.has_v1() || resumed.info_hashes.v1 == expected.v1)
        && (!expected.has_v2() || resumed.info_hashes.v2 == expected.v2);
      if (!ec && matching) {
        p = std::move(resumed);
        p.trackers.insert(p.trackers.end(), trackers.begin(), trackers.end());
        p.peers.insert(p.peers.end(), peers.begin(), peers.end());
      }
    }
    p.renamed_files.clear();
    p.save_path = e->payload;
    p.storage_mode = lt::storage_mode_sparse;
    p.flags &= ~(lt::torrent_flags::auto_managed | lt::torrent_flags::paused | lt::torrent_flags::seed_mode);
    p.flags |= lt::torrent_flags::default_dont_download;
    p.file_priorities.clear();
    p.piece_priorities.clear();
    if (p.ti) {
      if (p.ti->num_files() > 100000 || p.ti->num_pieces() > 1000000 || p.ti->piece_length() > 16 * 1024 * 1024)
        throw std::runtime_error("Torrent resume metadata exceeds supported file or piece limits");
      p.file_priorities.resize(p.ti->num_files(), lt::dont_download);
      p.piece_priorities.resize(p.ti->num_pieces(), lt::dont_download);
    }
    lt::settings_pack settings;
    settings.set_int(lt::settings_pack::alert_mask, int(static_cast<std::uint32_t>(lt::alert_category::error | lt::alert_category::storage | lt::alert_category::status)));
    // A torrent with zero demanded pieces is "finished". Keep metadata peers
    // available for later range demands rather than disconnecting every seed.
    settings.set_bool(lt::settings_pack::close_redundant_connections, false);
    settings.set_int(lt::settings_pack::min_reconnect_time, 1);
    settings.set_int(lt::settings_pack::connections_limit, 50);
    settings.set_int(lt::settings_pack::active_downloads, 1);
    settings.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:0,[::]:0");
    settings.set_str(lt::settings_pack::user_agent, "PlayGTA5/libtorrent " LIBTORRENT_VERSION);
    e->session = std::make_unique<lt::session>(settings);
    e->torrent = e->session->add_torrent(p, ec);
    if (ec) throw std::runtime_error("Cannot start torrent: " + ec.message());
  } catch (std::exception const& ex) { e->error = ex.what(); }
  return e;
}
char const* te_error(void* p) { return engine(p).error.c_str(); }
int te_poll(void* p) {
  auto& e = engine(p);
  if (!e.error.empty()) return -1;
  try {
    std::vector<lt::alert*> alerts;
    e.session->pop_alerts(&alerts);
    for (auto a : alerts) {
      if (std::getenv("TORRENT_ENGINE_DEBUG")) std::cerr << a->message() << "\n";
      if (auto r = lt::alert_cast<lt::read_piece_alert>(a)) {
        e.reading.erase(int(r->piece));
        if (!e.requested.count(int(r->piece))) continue;
        if (r->error) throw std::runtime_error("Cannot read verified torrent piece: " + r->error.message());
        e.pieces[int(r->piece)] = std::vector<char>(r->buffer.get(), r->buffer.get() + r->size);
      } else if (auto r = lt::alert_cast<lt::torrent_error_alert>(a)) {
        throw std::runtime_error("Torrent error: " + r->error.message());
      } else if (auto r = lt::alert_cast<lt::file_error_alert>(a)) {
        throw std::runtime_error("Torrent cache error: " + r->error.message());
      } else if (auto r = lt::alert_cast<lt::metadata_failed_alert>(a)) {
        throw std::runtime_error("Torrent metadata error: " + r->error.message());
      }
    }
    if (!e.info && e.torrent.status().has_metadata) metadata(e);
    // A piece requested while libtorrent still checks the cache after a restart becomes available through that check, not through a
    // download, so set_piece_deadline's alert_when_available never fires and the read waits forever (CI, offline reopen: "piece 1
    // timeout" with the piece cached). Requested pieces that are on disk but not delivered are read directly.
    if (e.info)
      for (int piece : e.requested)
        if (!e.pieces.count(piece) && !e.reading.count(piece) && e.torrent.have_piece(lt::piece_index_t(piece))) {
          e.reading.insert(piece);
          e.torrent.read_piece(lt::piece_index_t(piece));
        }
    if (!e.error.empty()) return -1;
    return e.info ? 1 : 0;
  } catch (std::exception const& ex) { e.error = ex.what(); e.torrent.pause(); return -1; }
}
int te_file_count(void* p) { auto& e=engine(p); return e.info ? e.info->num_files() : 0; }
char const* te_file_path(void* p, int file) { return engine(p).paths.at(file).c_str(); }
int64_t te_file_size(void* p, int file) { return engine(p).info->files().file_size(lt::file_index_t(file)); }
int64_t te_file_offset(void* p, int file) { return engine(p).info->files().file_offset(lt::file_index_t(file)); }
int te_piece_length(void* p) { return engine(p).info->piece_length(); }
int te_piece_size(void* p, int piece) { return engine(p).info->piece_size(lt::piece_index_t(piece)); }
int64_t te_downloaded(void* p) { auto& e=engine(p); return e.torrent.is_valid() ? e.torrent.status().total_download : 0; }
int64_t te_cached_bytes(void* p) { auto& e=engine(p); return e.torrent.is_valid() ? e.torrent.status().total_done : 0; }
void te_request_piece(void* p, int piece) {
  auto& e=engine(p);
  if (!e.requested.insert(piece).second) return;
  auto index=lt::piece_index_t(piece);
  e.torrent.piece_priority(index, lt::top_priority);
  e.torrent.set_piece_deadline(index, 0, lt::torrent_handle::alert_when_available);
  if (std::getenv("TORRENT_ENGINE_DEBUG")) { auto s=e.torrent.status(); std::cerr << "request " << piece << " priority " << int(static_cast<std::uint8_t>(e.torrent.piece_priority(index))) << " peers " << s.num_peers << " paused " << bool(s.flags & lt::torrent_flags::paused) << " state " << int(s.state) << "\n"; }
}
int te_copy_piece(void* p, int piece, uint8_t* buffer, int capacity) {
  auto& e=engine(p);
  if (!e.error.empty()) return -1;
  auto it=e.pieces.find(piece);
  if (it==e.pieces.end()) return 0;
  if (!buffer) return int(it->second.size());
  if (capacity<int(it->second.size())) return -1;
  std::memcpy(buffer, it->second.data(), it->second.size());
  return int(it->second.size());
}
void te_release_piece(void* p, int piece) {
  auto& e=engine(p);
  e.requested.erase(piece);
  e.pieces.erase(piece);
  e.reading.erase(piece);
  auto index=lt::piece_index_t(piece);
  e.torrent.reset_piece_deadline(index);
  e.torrent.piece_priority(index, lt::dont_download);
}
void te_close(void* p) {
  auto& e=engine(p);
  if (e.session && e.torrent.is_valid()) {
    try {
      e.torrent.pause();
      e.torrent.clear_piece_deadlines();
      e.torrent.save_resume_data(lt::torrent_handle::save_info_dict | lt::torrent_handle::flush_disk_cache);
      auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
      bool saved=false;
      while (!saved && std::chrono::steady_clock::now()<deadline) {
        e.session->wait_for_alert(std::chrono::milliseconds(100));
        std::vector<lt::alert*> alerts;
        e.session->pop_alerts(&alerts);
        for(auto a:alerts) {
          if(auto r=lt::alert_cast<lt::save_resume_data_alert>(a)) {
            auto bytes=lt::write_resume_data_buf(r->params);
            auto target=fs::u8path(e.cache)/"resume.dat";
            auto temp=fs::u8path(e.cache)/"resume.tmp";
            if (fs::is_symlink(fs::symlink_status(temp))) throw std::runtime_error("Torrent resume temporary file is a symlink");
            std::ofstream out(temp,std::ios::binary|std::ios::trunc);
            out.write(bytes.data(),bytes.size());out.close();
            if(out) { std::error_code ec; fs::remove(target,ec); fs::rename(temp,target); }
            saved=true;
          } else if(lt::alert_cast<lt::save_resume_data_failed_alert>(a)) saved=true;
        }
      }
      e.session->remove_torrent(e.torrent);
    } catch (...) { /* Disposal still releases all peers and native resources. */ }
  }
  delete &e;
}
}
