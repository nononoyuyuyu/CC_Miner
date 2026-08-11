-- CC Miner V4 distribution manifest (schema 4).
--
-- ``files`` is the source of truth for role-scoped runtime distribution.
-- Every entry is intentionally explicit: a file is installed only when the
-- selected role is present in its ``roles`` map.  The online installer and
-- offline bundle generator mirror this table because ComputerCraft cannot
-- import a repository-local manifest over HTTP.
return {
  name = "CC Miner V4",
  version = "4.0.0",
  schema = 4,
  repository = "nononoyuyuyu/CC_Miner",
  files = {
    -- Shared bootstrap and libraries.
    { source = "src/ccminer/lib/common.lua", target = "lib/common.lua",
      roles = { worker = true, controller = true, gps = true } },
    { source = "src/ccminer/lib/protocol.lua", target = "lib/protocol.lua",
      roles = { worker = true, controller = true, gps = true } },
    { source = "src/ccminer/setup.lua", target = "setup.lua",
      roles = { worker = true, controller = true, gps = true } },
    { source = "src/ccminer/boot.lua", target = "boot.lua",
      roles = { worker = true, controller = true, gps = true } },
    { source = "src/ccminer/command.lua", target = "command.lua",
      roles = { worker = true, controller = true, gps = true } },

    -- Worker-only runtime.
    { source = "src/ccminer/lib/geo.lua", target = "lib/geo.lua",
      roles = { worker = true } },
    { source = "src/ccminer/lib/quarry.lua", target = "lib/quarry.lua",
      roles = { worker = true, controller = true } },
    { source = "src/ccminer/worker.lua", target = "worker.lua",
      roles = { worker = true } },
    { source = "src/ccminer/worker_parts/01.part", target = "worker_parts/01.part",
      roles = { worker = true } },
    { source = "src/ccminer/worker_parts/02.part", target = "worker_parts/02.part",
      roles = { worker = true } },
    { source = "src/ccminer/worker_parts/03.part", target = "worker_parts/03.part",
      roles = { worker = true } },
    { source = "src/ccminer/worker_parts/04.part", target = "worker_parts/04.part",
      roles = { worker = true } },
    { source = "src/ccminer/worker_parts/05.part", target = "worker_parts/05.part",
      roles = { worker = true } },

    -- Controller-only runtime.  controller_parts use quarry directly; no
    -- geo module is referenced by the assembled controller source.
    { source = "src/ccminer/controller.lua", target = "controller.lua",
      roles = { controller = true } },
    { source = "src/ccminer/controller_parts/01.part", target = "controller_parts/01.part",
      roles = { controller = true } },
    { source = "src/ccminer/controller_parts/02.part", target = "controller_parts/02.part",
      roles = { controller = true } },
    { source = "src/ccminer/controller_parts/03.part", target = "controller_parts/03.part",
      roles = { controller = true } },

    -- GPS host has no worker/controller implementation dependency.
    { source = "src/ccminer/gps_host.lua", target = "gps_host.lua",
      roles = { gps = true } },
  },
}
