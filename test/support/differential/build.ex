defmodule Taskweft.Differential.Build do
  @moduledoc """
  Builds test-only copies of the planner NIF: `standalone/tw_planner.hpp` with
  trace hooks patched in, plus one build-time variant per negative control.
  Every patch names how many times its anchor must occur, so a planner edit
  that moves an anchor fails the build instead of silently skipping a hook.
  """

  @root Path.expand("../../..", __DIR__)
  @nif_src Path.join(__DIR__, "tw_diff_nif.cpp")

  @instrument [
    {"            fired = true;\n",
     "            fired = true;\n            tw_diff_budget_fired();\n", 1},
    {"        if (fired) return true;\n        if ((++tick",
     "        if (fired) return true;\n        if (tw_diff_step()) { fired = true; return true; }\n        if ((++tick",
     1},
    {"""
         TwMemoKey cache_key = 0;
         if (fail_cache) {
             cache_key = tw_search_key(*state, tasks);
             if (fail_cache->count(cache_key)) return std::nullopt;
         }
         if (success_cache) {
     """,
     """
         TwMemoKey cache_key = 0;
         const std::string diff_entry = (fail_cache || success_cache) ? tw_diff_exact(*state, tasks) : std::string();
         if (fail_cache) {
             cache_key = tw_search_key(*state, tasks);
             if (fail_cache->count(cache_key)) { tw_diff_key(0, cache_key, diff_entry); return std::nullopt; }
         }
         if (success_cache) {
     """, 1},
    {"if (sit != success_cache->end()) return sit->second;",
     "if (sit != success_cache->end()) { tw_diff_key(1, cache_key, diff_entry); return sit->second; }",
     1},
    {"if (fail_cache && cache_key != 0) fail_cache->insert(cache_key);\n        return std::nullopt;\n    };\n    auto mark_success",
     "if (fail_cache && cache_key != 0) { tw_diff_key(0, cache_key, diff_entry); fail_cache->insert(cache_key); }\n        return std::nullopt;\n    };\n    auto mark_success",
     1},
    {"if (success_cache && cache_key != 0) (*success_cache)[cache_key] = plan;",
     "if (success_cache && cache_key != 0) { tw_diff_key(1, cache_key, diff_entry); (*success_cache)[cache_key] = plan; }",
     1},
    {"ait0->second(state->copy(), call0.args);\n",
     "ait0->second(state->copy(), call0.args);\n        tw_diff_action(call0, new_state != nullptr);\n",
     1},
    {"// Pick first unsatisfied binding; try all goal methods for its var.\n        const TwGoalBinding &b = unmet[0];\n",
     "// Pick first unsatisfied binding; try all goal methods for its var.\n        const TwGoalBinding &b = unmet[0];\n        tw_diff_goal('Q', 0, unmet.size(), b);\n",
     1},
    {"            sub_goal.bindings = {unmet[uidx]};\n",
     "            sub_goal.bindings = {unmet[uidx]};\n            tw_diff_goal('N', uidx, unmet.size(), unmet[uidx]);\n",
     1},
    {"const uint64_t gkey = tw_method_call_hash(gcall.name, gcall.args);\n",
     "const uint64_t gkey = tw_method_call_hash(gcall.name, gcall.args);\n        tw_diff_stats(gkey, gcall.name, gcall.args);\n",
     1},
    {"const uint64_t tkey = tw_method_call_hash(call.name, call.args);\n",
     "const uint64_t tkey = tw_method_call_hash(call.name, call.args);\n        tw_diff_stats(tkey, call.name, call.args);\n",
     1},
    {"method(state, goal_args);\n",
     "method(state, goal_args);\n            tw_diff_method('G', gcall.name, midx, goal_args, subs);\n",
     1},
    {"method(state, call.args);\n",
     "method(state, call.args);\n            tw_diff_method('T', call.name, midx, call.args, subs);\n",
     1},
    {"method_stats);\n        std::unordered_set<uint64_t> seen_decompositions;\n",
     "method_stats);\n        TwDiffSeen seen_decompositions;\n", 2},
    {"if (!seen_decompositions.insert(decomp_sig).second) continue;",
     "if (!seen_decompositions.insert(decomp_sig, new_tasks).second) continue;", 2}
  ]

  @variants %{
    base: [],
    norequeue: [
      {"            new_tasks.push_back(*goal);\n            new_tasks.insert(new_tasks.end(), remaining.begin(), remaining.end());\n            const uint64_t decomp_sig = tw_tasks_hash(new_tasks);\n            if (!seen_decompositions.insert(decomp_sig, new_tasks)",
       "            new_tasks.insert(new_tasks.end(), remaining.begin(), remaining.end());\n            const uint64_t decomp_sig = tw_tasks_hash(new_tasks);\n            if (!seen_decompositions.insert(decomp_sig, new_tasks)",
       1}
    ],
    nofailcache: [
      {"blacklist, budget, &fail_cache, &success_cache, &method_stats);",
       "blacklist, budget, nullptr, &success_cache, &method_stats);", 1}
    ],
    nosuccesscache: [
      {"blacklist, budget, &fail_cache, &success_cache, &method_stats);",
       "blacklist, budget, &fail_cache, nullptr, &method_stats);", 1}
    ],
    nobestfirst: [
      {"    if (best_score > 0 && best_idx != 0) std::swap(order[0], order[best_idx]);\n", "", 1}
    ],
    fuel399: [
      {"static constexpr int TW_MAX_DEPTH = 400;", "static constexpr int TW_MAX_DEPTH = 399;", 1}
    ],
    collide: [
      {"    h = tw_mix_hash(h, tw_tasks_hash(tasks));\n    return h;\n",
       "    h = tw_mix_hash(h, tw_tasks_hash(tasks));\n    return (h & 0xf) + 1;\n", 1},
      {"        h = tw_mix_hash(h, tw_task_hash(t));\n    return h;\n",
       "        h = tw_mix_hash(h, tw_task_hash(t));\n    return h & 0xf;\n", 1}
    ],
    collide_stats: [
      {"    for (const TwValue &a : args) h = tw_mix_hash(h, a.stable_hash());\n    return h;\n",
       "    for (const TwValue &a : args) h = tw_mix_hash(h, a.stable_hash());\n    return h & 0xf;\n",
       1}
    ]
  }

  def variants, do: Map.keys(@variants)

  def patch(text, patches) do
    Enum.reduce(patches, text, fn {anchor, replacement, expected}, acc ->
      found = length(:binary.matches(acc, anchor))

      if found != expected do
        raise "planner anchor found #{found} times, expected #{expected}: #{inspect(anchor)}"
      end

      String.replace(acc, anchor, replacement)
    end)
  end

  def build(names) do
    names
    |> Task.async_stream(&{&1, build_one(&1)}, timeout: :infinity, ordered: true)
    |> Map.new(fn {:ok, {name, mod}} -> {name, mod} end)
  end

  defp build_one(name) do
    dir = Path.join([Mix.Project.build_path(), "differential", "build", Atom.to_string(name)])
    File.mkdir_p!(dir)

    planner =
      Path.join(@root, "standalone/tw_planner.hpp")
      |> File.read!()
      |> patch(@instrument)
      |> patch(Map.fetch!(@variants, name))

    module = Module.concat([Taskweft.Differential.Native, Macro.camelize(Atom.to_string(name))])
    lib = Path.join(dir, "tw_diff")
    args = compile_args(dir, lib, module)
    stamp = :crypto.hash(:sha256, [planner, File.read!(@nif_src), Enum.join(args, " ")])
    stamp_path = Path.join(dir, "stamp")

    unless File.exists?(lib <> ".so") and File.read(stamp_path) == {:ok, stamp} do
      File.write!(Path.join(dir, "tw_planner.hpp"), planner)
      {out, status} = System.cmd(System.get_env("CXX", "c++"), args, stderr_to_stdout: true)
      if status != 0, do: raise("#{name} build failed:\n#{out}")
      File.write!(stamp_path, stamp)
    end

    load(module, lib)
  end

  defp compile_args(dir, lib, module) do
    erts = Path.join(:code.root_dir(), "erts-#{:erlang.system_info(:version)}/include")

    [
      "-std=gnu++20",
      "-O2",
      "-fPIC",
      "-fvisibility=hidden",
      "-I#{dir}",
      "-I#{Path.join(@root, "standalone")}",
      "-I#{erts}",
      ~s(-DTW_DIFF_MODULE="#{module}"),
      "-shared",
      @nif_src,
      "-o",
      lib <> ".so"
    ] ++
      if(match?({:unix, :darwin}, :os.type()), do: ["-undefined", "dynamic_lookup"], else: [])
  end

  defp load(module, lib) do
    body =
      quote do
        def load(path), do: :erlang.load_nif(path, 0)

        def plan(_domain, _problem, _budget_ms, _step_limit, _trace),
          do: :erlang.nif_error(:not_loaded)
      end

    unless Code.ensure_loaded?(module),
      do: Module.create(module, body, Macro.Env.location(__ENV__))

    :ok = module.load(String.to_charlist(lib))
    module
  end
end
