// Copyright (c) 2026 PlayGTA5. BSD-3-Clause; see LICENSE.
#include "torrent_engine.h"
#include <libtorrent/session.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/bencode.hpp>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <thread>
#include <stdexcept>
#include <random>
#include <chrono>
namespace lt=libtorrent;
namespace fs=std::filesystem;
static void check(bool valid,std::string const& message) { if(!valid) throw std::runtime_error(message); }
// Phase markers on stderr, so a CI timeout shows which step stalled and for how long.
static void step(char const* name) {
  static auto const start=std::chrono::steady_clock::now();
  auto const ms=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-start).count();
  std::cerr<<"[step "<<ms<<" ms] "<<name<<std::endl;
}
static std::vector<char> pattern(int size,int seed) {
  std::vector<char> bytes(size);
  for(int i=0;i<size;i++) bytes[i]=char((i*31+seed)%251);
  return bytes;
}
static void write(fs::path const& path,std::vector<char> const& bytes) {
  fs::create_directories(path.parent_path());
  std::ofstream file(path,std::ios::binary);file.write(bytes.data(),bytes.size());
}
static bool metadata(void* e) {
  for(int i=0;i<800;i++) {
    auto status=te_poll(e);
    check(status>=0,te_error(e));
    if(status==1) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
  }
  return false;
}
static std::vector<char> read(void* e,int piece) {
  te_request_piece(e,piece);
  for(int i=0;i<800;i++) {
    check(te_poll(e)>=0,te_error(e));
    auto size=te_copy_piece(e,piece,nullptr,0);
    check(size>=0,te_error(e));
    if(size>0) {
      std::vector<char> bytes(size);
      check(te_copy_piece(e,piece,reinterpret_cast<uint8_t*>(bytes.data()),size)==size,"piece size");
      te_release_piece(e,piece);
      return bytes;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
  }
  throw std::runtime_error("piece "+std::to_string(piece)+" timeout (downloaded "+std::to_string(te_downloaded(e))
    +" bytes, cached "+std::to_string(te_cached_bytes(e))+" bytes)");
}
static fs::path unique_fixture_root() {
  std::random_device random;
  for (int attempt=0; attempt<64; ++attempt) {
    auto const stamp=std::chrono::high_resolution_clock::now().time_since_epoch().count();
    auto const name="playgta5-engine-fixture-"+std::to_string(stamp)+"-"+std::to_string(random());
    auto const candidate=fs::temp_directory_path()/name;
    // Creation is atomic: a collision retries without touching another fixture.
    if (fs::create_directory(candidate)) return candidate;
  }
  throw std::runtime_error("Cannot allocate a unique fixture directory");
}
int main(int argc,char** argv) {
  fs::path root;
  try {
    if (argc>1) {
      root=fs::u8path(argv[1]);
      fs::remove_all(root);
      fs::create_directories(root);
    } else {
      root=unique_fixture_root();
    }
    auto a=pattern(40000,3),b=pattern(110000,7);
    write(root/"seed/fixture/a.bin",a);write(root/"seed/fixture/b.bin",b);
    lt::file_storage files;files.add_file("fixture/a.bin",a.size());files.add_file("fixture/b.bin",b.size());
    lt::create_torrent created(files,32768,lt::create_torrent::v1_only);
    lt::set_piece_hashes(created,(root/"seed").string());
    std::vector<char> encoded;lt::bencode(std::back_inserter(encoded),created.generate());
    auto info=std::make_shared<lt::torrent_info>(encoded.data(),int(encoded.size()));
    lt::settings_pack settings;
    settings.set_str(lt::settings_pack::listen_interfaces,"127.0.0.1:0");
    settings.set_bool(lt::settings_pack::enable_dht,false);
    settings.set_bool(lt::settings_pack::enable_lsd,false);
    settings.set_bool(lt::settings_pack::enable_upnp,false);
    settings.set_bool(lt::settings_pack::enable_natpmp,false);
    lt::session seed(settings);
    lt::add_torrent_params params;params.ti=info;params.save_path=(root/"seed").string();
    params.flags=lt::torrent_flags::seed_mode;
    auto handle=seed.add_torrent(params);
    int port=0;
    for(int i=0;i<100 && port==0;i++) {port=seed.listen_port();std::this_thread::sleep_for(std::chrono::milliseconds(20));}
    check(port>0,"seed listen port");
    auto magnet=lt::make_magnet_uri(handle)+"&x.pe=127.0.0.1:"+std::to_string(port);
    if(argc>2 && std::string(argv[2])=="--serve") {
      std::cout<<magnet<<std::endl;
      std::string line;std::getline(std::cin,line);
      return 0;
    }
    step("open engine");
    auto* engine=te_open(magnet.c_str(),(root/"cache").string().c_str());
    check(std::string(te_error(engine)).empty(),te_error(engine));
    check(metadata(engine),"metadata timeout");
    check(te_file_count(engine)==2,"file count");
    check(std::string(te_file_path(engine,0))=="fixture/a.bin","file path");
    check(te_file_size(engine,1)==110000,"file size");
    // Metadata is discovered without downloading autonomous payload pieces.
    std::this_thread::sleep_for(std::chrono::milliseconds(200));te_poll(engine);
    check(te_cached_bytes(engine)==0,"unexpected autonomous download");
    step("request pieces 1 and 2");
    te_request_piece(engine,1);te_request_piece(engine,2);
    auto piece1=read(engine,1),piece2=read(engine,2);
    std::vector<char> whole=a;whole.insert(whole.end(),b.begin(),b.end());
    check(std::equal(piece1.begin(),piece1.end(),whole.begin()+32768),"cross-file piece bytes");
    check(std::equal(piece2.begin(),piece2.end(),whole.begin()+65536),"concurrent piece bytes");
    check(te_cached_bytes(engine)<int64_t(whole.size()),"downloaded full torrent");
    step("cancel piece 4 and close");
    te_request_piece(engine,4);te_release_piece(engine,4);
    te_close(engine);
    check(fs::exists(root/"cache/resume.dat"),"resume saved");
    step("reopen offline");
    seed.remove_torrent(handle);
    engine=te_open(magnet.c_str(),(root/"cache").string().c_str());
    check(metadata(engine),"metadata resume offline");
    check(read(engine,1)==piece1,"verified payload resume offline");
    te_close(engine);
    step("disk usage");
    check(te_disk_usage((root/"cache").string().c_str())>0,"allocated cache usage");
    std::cout<<"PASS metadata, no autonomous payload, concurrent verified cross-file pieces, cancellation, offline resume, disk usage\n";
    fs::remove_all(root);
    return 0;
  } catch(std::exception const& error) {
    std::cerr<<error.what()<<std::endl;return 1;
  }
}
