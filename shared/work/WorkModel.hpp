// KuroCatWork cross-platform state model. No OS, rendering, network or account dependencies.
#pragma once
#include <algorithm>
#include <cmath>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace kurowork {
enum class Tool { Codex, Claude };
enum class State { Running, Awaiting, Completed, Failed, Cancelled };
enum class Selection { Codex, Claude, Both, Automatic };
struct Window {
    double used = 0;
    std::optional<double> resetsAt;
    double remaining() const { return std::clamp(100.0 - used, 0.0, 100.0); }
};
struct Quota {
    std::optional<Window> session, week;
    double updatedAt = 0;
    bool stale = true;
    std::string message;
};
struct Task {
    std::string key, turn, title, link, project, source;
    Tool tool = Tool::Codex;
    State state = State::Running;
    double startedAt = 0, changedAt = 0;
    bool read = false;
};
struct Options {
    Selection selection = Selection::Codex;
    bool autonomousTyping = true, randomExpressions = true, typingBubbles = true;
    bool sound = false, popSound = true;
    int switchType = 0;
    double keyboardVolume = 0.35, meowVolume = 0.5, popVolume = 0.4;
};
struct TypingFrame { bool active = false, slow = false; double interval = 0.08; };

class Model {
public:
    Options options;
    bool enabled = false;
    std::map<Tool, Quota> quotas;
    std::set<Tool> detected;
    // Preserve unread waiting/failure items and completion tombstones in native settings adapters.
    std::map<std::string, Task> tasks;
    std::set<std::string> dismissed;
    std::map<std::string, double> fading;
    double lastBusyAt = 0, nextTaskPoll = 0, nextQuotaPoll = 0;

    static std::string identity(const Task& task) {
        // Completed turns must not reopen just because a polling result is replayed.
        return task.key + "\n" + (task.turn.empty() ? std::to_string(task.startedAt) : task.turn);
    }
    bool shows(Tool tool) const {
        switch (options.selection) {
        case Selection::Both: return true;
        case Selection::Automatic: return detected.count(tool) != 0;
        case Selection::Claude: return tool == Tool::Claude;
        default: return tool == Tool::Codex;
        }
    }
    bool waiting() const {
        for (const auto& pair : tasks)
            if (!pair.second.read && shows(pair.second.tool) && pair.second.state == State::Awaiting) return true;
        return false;
    }
    bool running() const {
        for (const auto& pair : tasks)
            if (!pair.second.read && shows(pair.second.tool) && pair.second.state == State::Running) return true;
        return false;
    }
    static bool busy(State state) { return state == State::Running || state == State::Awaiting; }
    std::vector<Task> visible(bool all = false) const {
        std::vector<Task> result;
        if (!enabled) return result;
        for (const auto& pair : tasks)
            if (shows(pair.second.tool) && (!pair.second.read || fading.count(pair.first))) result.push_back(pair.second);
        auto rank = [](State state) { return state == State::Awaiting ? 0 : state == State::Running ? 1 : 2; };
        std::stable_sort(result.begin(), result.end(), [&](const Task& a, const Task& b) {
            if (rank(a.state) != rank(b.state)) return rank(a.state) < rank(b.state);
            return a.startedAt < b.startedAt;
        });
        if (!all && result.size() > 3) result.resize(3);
        return result;
    }
    void enter(double now) {
        enabled = true; lastBusyAt = now; nextTaskPoll = nextQuotaPoll = now;
        activeTypingTime_ = 0;
    }
    void leave(double now) {
        if (!enabled) return;
        for (auto& pair : tasks) {
            auto& task = pair.second;
            if (task.state == State::Completed) dismiss(pair.first, now);
        }
        enabled = false;
        // Native source adapters must cancel outstanding IO when enabled changes to false.
    }
    void dismiss(const std::string& key, double now) {
        auto found = tasks.find(key);
        if (found == tasks.end()) return;
        found->second.read = true;
        dismissed.insert(identity(found->second));
        fading[key] = now;
    }
    // Polling is explicit and read-only. Callers pass wall-clock seconds; animations use monotonic dt.
    bool takeTaskPoll(double now) {
        if (!enabled || now < nextTaskPoll) return false;
        nextTaskPoll = now + 6; return true;
    }
    bool takeQuotaPoll(double now) {
        if (!enabled || now < nextQuotaPoll) return false;
        nextQuotaPoll = now + 60; return true;
    }
    // Source errors do not clear current tasks. Pass only a successfully read source snapshot.
    void merge(const std::vector<Task>& snapshot) {
        if (!enabled) return;
        for (auto incoming : snapshot) {
            if (incoming.key.empty() || !std::isfinite(incoming.changedAt) || !std::isfinite(incoming.startedAt)) continue;
            if (options.selection == Selection::Automatic && busy(incoming.state)) detected.insert(incoming.tool);
            auto old = tasks.find(incoming.key);
            if (old != tasks.end() && incoming.changedAt < old->second.changedAt) continue;
            incoming.read = dismissed.count(identity(incoming)) != 0;
            if (old != tasks.end() && identity(old->second) == identity(incoming)) incoming.read |= old->second.read;
            if (old == tasks.end() || identity(old->second) != identity(incoming)) fading.erase(incoming.key);
            tasks[incoming.key] = std::move(incoming);
        }
    }
    void tick(double now) {
        for (auto it = fading.begin(); it != fading.end();) {
            if (now - it->second >= 0.8) it = fading.erase(it); else ++it;
        }
        if (!enabled) return;
        if (running() || waiting()) lastBusyAt = now;
        else if (now - lastBusyAt >= 1800) leave(now);
    }
    bool angryWaiting(double now) const {
        if (!enabled) return false;
        for (const auto& pair : tasks) {
            const auto& task = pair.second;
            if (!task.read && shows(task.tool) && task.state == State::Awaiting && now - task.changedAt >= 300) return true;
        }
        return false;
    }
    TypingFrame typing(double dt, bool dragging, bool petting, bool realInput) {
        (void)realInput; // Task-driven typing is independent of physical keyboard activity.
        TypingFrame frame;
        frame.active = enabled && options.autonomousTyping && running() && !waiting() && !dragging && !petting;
        if (!frame.active) return frame;
        activeTypingTime_ += std::clamp(dt, 0.0, 0.1);
        // Slow thinking phrases occur once or twice per active minute, for exactly three seconds.
        double local = std::fmod(activeTypingTime_, 60.0);
        for (double start : {20.0, 46.0}) {
            double age = local - start;
            if (age < 0 || age >= 3) continue;
            frame.slow = age < 2.4;
            if (frame.slow) frame.interval = std::fmod(age, 1.2) < 1.0 ? 0.25 : 0.5;
            else {
                double u = (age - 2.4) / 0.6;
                frame.interval = 0.25 + (0.08 - 0.25) * u * u * (3 - 2*u);
            }
        }
        return frame;
    }
private:
    double activeTypingTime_ = 0;
};

struct Rect { double x, y, width, height; };
// Keep cards beside their anchor and fully within the current monitor's usable bounds.
inline Rect placeHover(Rect anchor, double width, double height, Rect screen) {
    constexpr double gap = 8;
    width = std::min(width, screen.width); height = std::min(height, screen.height);
    double x = anchor.x + anchor.width + gap;
    if (x + width > screen.x + screen.width) x = anchor.x - width - gap;
    return {std::clamp(x, screen.x, screen.x + screen.width-width),
            std::clamp(anchor.y, screen.y, screen.y + screen.height-height), width, height};
}
} // namespace kurowork
