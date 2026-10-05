// Test-only NIF: plans with an instrumented copy of tw_planner.hpp and reports
// the oracle-request trace, budget and step-budget hits and memo-key hash collisions.
#include <fine.hpp>
#include "tw_domain.hpp"
#include "tw_json.hpp"

#include <algorithm>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <optional>
#include <stdexcept>
#include <string>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <vector>

struct TwDiffCtx {
    uint64_t hash = 1469598103934665603ull;
    int64_t events = 0;
    int64_t bytes = 0;
    std::FILE *out = nullptr;
    bool budget_fired = false;
    int64_t steps = 0;
    int64_t step_limit = 0;
    bool steps_fired = false;
    std::vector<int64_t> collisions = std::vector<int64_t>(4, 0);
    std::unordered_map<uint64_t, std::string> shadow[3];
};

static thread_local TwDiffCtx *tw_diff_ctx = nullptr;

static void tw_diff_value(std::string &out, const TwValue &v) {
    out += char('0' + int(v.type()));
    switch (v.type()) {
        case TwValue::Type::NIL:
            break;
        case TwValue::Type::BOOL:
            out += v.as_bool() ? '1' : '0';
            break;
        case TwValue::Type::INT:
            out += std::to_string(v.as_int());
            out += ';';
            break;
        case TwValue::Type::FLOAT: {
            double f = v.as_float();
            if (f == 0.0) f = 0.0;
            uint64_t bits = std::isnan(f) ? 0x7ff8000000000000ull : std::bit_cast<uint64_t>(f);
            out += std::to_string(bits);
            out += ';';
            break;
        }
        case TwValue::Type::STRING:
            out += std::to_string(v.as_string().size());
            out += ':';
            out += v.as_string();
            break;
        case TwValue::Type::ARRAY:
            out += std::to_string(v.as_array().size());
            out += '[';
            for (const TwValue &e : v.as_array()) tw_diff_value(out, e);
            break;
        case TwValue::Type::DICT: {
            std::vector<std::string> keys;
            for (const std::pair<std::string, TwValue> &kv : v.as_dict()) keys.push_back(kv.first);
            std::sort(keys.begin(), keys.end());
            out += std::to_string(keys.size());
            out += '{';
            for (const std::string &k : keys) {
                out += std::to_string(k.size());
                out += ':';
                out += k;
                tw_diff_value(out, v.as_dict().at(k));
            }
            break;
        }
    }
}

static void tw_diff_bindings(std::string &out, const std::vector<TwGoalBinding> &bs) {
    out += std::to_string(bs.size());
    for (const TwGoalBinding &b : bs) {
        out += std::to_string(b.var.size()) + ':' + b.var;
        out += std::to_string(b.key.size()) + ':' + b.key;
        tw_diff_value(out, b.desired);
    }
}

static std::string tw_diff_tasks(const std::vector<TwTask> &tasks) {
    std::string out = std::to_string(tasks.size());
    for (const TwTask &t : tasks) {
        if (const TwCall *c = std::get_if<TwCall>(&t)) {
            out += 'C' + std::to_string(c->name.size()) + ':' + c->name;
            tw_diff_value(out, TwValue(TwValue::Array(c->args)));
        } else if (const TwGoal *g = std::get_if<TwGoal>(&t)) {
            out += 'G';
            tw_diff_bindings(out, g->bindings);
        } else {
            out += 'M';
            tw_diff_bindings(out, std::get<TwMultiGoal>(t).bindings);
        }
    }
    return out;
}

// Same canonical form signature_hash uses: variables by sorted name.
static std::string tw_diff_exact(const TwState &state, const std::vector<TwTask> &tasks) {
    std::vector<std::string> keys;
    for (const std::pair<std::string, TwValue> &kv : state.vars) keys.push_back(kv.first);
    std::sort(keys.begin(), keys.end());
    std::string out = std::to_string(keys.size());
    for (const std::string &k : keys) {
        out += std::to_string(k.size()) + ':' + k;
        tw_diff_value(out, state.vars.at(k));
    }
    return out + '|' + tw_diff_tasks(tasks);
}

// kind 0 = fail cache, 1 = success cache, 2 = method-stats key, 3 = decomposition dedupe.
static void tw_diff_key(int kind, uint64_t key, const std::string &exact) {
    TwDiffCtx *c = tw_diff_ctx;
    if (!c) return;
    std::pair<std::unordered_map<uint64_t, std::string>::iterator, bool> r =
        c->shadow[kind].emplace(key, exact);
    if (!r.second && r.first->second != exact) {
        c->collisions[kind]++;
        r.first->second = exact;
    }
}

static void tw_diff_emit(const std::string &line) {
    TwDiffCtx *c = tw_diff_ctx;
    if (!c) return;
    for (unsigned char ch : line) {
        c->hash ^= ch;
        c->hash *= 1099511628211ull;
    }
    c->hash ^= '\n';
    c->hash *= 1099511628211ull;
    c->events++;
    c->bytes += int64_t(line.size()) + 1;
    if (c->out) {
        std::fwrite(line.data(), 1, line.size(), c->out);
        std::fputc('\n', c->out);
    }
}

static std::string tw_diff_args(const std::vector<TwValue> &args) {
    return TwJson::to_json(TwValue(TwValue::Array(args)));
}

static void tw_diff_budget_fired() {
    if (tw_diff_ctx) tw_diff_ctx->budget_fired = true;
}

static bool tw_diff_step() {
    TwDiffCtx *c = tw_diff_ctx;
    if (!c || ++c->steps <= c->step_limit) return false;
    c->steps_fired = true;
    return true;
}

static void tw_diff_action(const TwCall &call, bool ok) {
    tw_diff_emit("A " + call.name + ' ' + tw_diff_args(call.args) + (ok ? " ok" : " fail"));
}

static void tw_diff_method(char kind, const std::string &name, size_t idx,
                           const std::vector<TwValue> &args,
                           const std::optional<std::vector<TwTask>> &subs) {
    tw_diff_emit(std::string(1, kind) + ' ' + name + '#' + std::to_string(idx) + ' ' +
                 tw_diff_args(args) + ' ' + (subs ? std::to_string(subs->size()) : "fail"));
}

static void tw_diff_stats(uint64_t key, const std::string &name, const std::vector<TwValue> &args) {
    std::string exact = std::to_string(name.size()) + ':' + name;
    tw_diff_value(exact, TwValue(TwValue::Array(args)));
    tw_diff_key(2, key, exact);
}

static void tw_diff_goal(char kind, size_t idx, size_t unmet, const TwGoalBinding &b) {
    tw_diff_emit(std::string(1, kind) + ' ' + std::to_string(idx) + '/' + std::to_string(unmet) +
                 ' ' + b.var + ' ' + TwJson::to_json(TwValue(b.key)) + ' ' +
                 TwJson::to_json(b.desired));
}

struct TwDiffSeen {
    struct Inserted {
        bool second;
    };
    std::unordered_set<uint64_t> sigs;
    std::unordered_map<uint64_t, std::string> exact;

    Inserted insert(uint64_t sig, const std::vector<TwTask> &tasks) {
        std::string e = tw_diff_tasks(tasks);
        std::pair<std::unordered_map<uint64_t, std::string>::iterator, bool> r = exact.emplace(sig, e);
        if (!r.second && r.first->second != e && tw_diff_ctx) tw_diff_ctx->collisions[3]++;
        return Inserted{sigs.insert(sig).second};
    }
};

#include "tw_planner.hpp"
#include "tw_loader.hpp"

using TwDiffResult = std::tuple<std::string, std::string, uint64_t, int64_t, int64_t, bool, int64_t,
                                bool, std::vector<int64_t>, int64_t>;

struct TwDiffJob {
    std::string domain_path, problem_path, trace_path;
    int64_t budget_ms, step_limit;
    TwDiffResult result;
};

static void *tw_diff_job(void *p_job) {
    TwDiffJob &job = *static_cast<TwDiffJob *>(p_job);
    TwLoader::TwLoaded loaded = job.problem_path.empty()
        ? TwLoader::load_file(job.domain_path)
        : TwLoader::load_file_pair(job.domain_path, job.problem_path);
    if (!loaded.state) {
        job.result = TwDiffResult{"load_error", "", 0, 0, 0, false, 0, false, std::vector<int64_t>(4, 0), 0};
        return nullptr;
    }

    TwDiffCtx ctx;
    ctx.step_limit = job.step_limit;
    if (!job.trace_path.empty()) ctx.out = std::fopen(job.trace_path.c_str(), "wb");
    tw_diff_ctx = &ctx;
    std::chrono::steady_clock::time_point t0 = std::chrono::steady_clock::now();
    std::optional<std::vector<TwCall>> result = tw_plan(loaded.state, loaded.tasks, loaded.domain,
                                                        nullptr, std::chrono::milliseconds(job.budget_ms));
    int64_t us = std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now() - t0).count();
    tw_diff_ctx = nullptr;
    if (ctx.out) std::fclose(ctx.out);

    job.result = TwDiffResult{result ? "ok" : "no_plan", result ? TwLoader::plan_to_json(*result) : "",
                              ctx.hash, ctx.events, ctx.bytes, ctx.budget_fired, ctx.steps,
                              ctx.steps_fired, ctx.collisions, us};
    return nullptr;
}

// Dirty schedulers get a 320 KB stack; the search recurses up to TW_MAX_DEPTH
// frames, so it runs on its own thread with the stack set explicitly.
TwDiffResult plan(ErlNifEnv *p_env, std::string p_domain_path, std::string p_problem_path,
                  int64_t p_budget_ms, int64_t p_step_limit, std::string p_trace_path) {
    TwDiffJob job{p_domain_path, p_problem_path, p_trace_path, p_budget_ms, p_step_limit, {}};
    ErlNifThreadOpts *opts = enif_thread_opts_create(const_cast<char *>("tw_diff"));
    opts->suggested_stack_size = 1024;
    ErlNifTid tid;
    int rc = enif_thread_create(const_cast<char *>("tw_diff"), &tid, tw_diff_job, &job, opts);
    enif_thread_opts_destroy(opts);
    if (rc != 0) throw std::runtime_error("thread_create_failed");
    enif_thread_join(tid, nullptr);
    return job.result;
}
FINE_NIF(plan, ERL_NIF_DIRTY_JOB_CPU_BOUND);

FINE_INIT(TW_DIFF_MODULE);
