#pragma once
#include <cmath>
#include <algorithm>

inline bool YTKACETranslationNeedsSeek(double videoTime, double audioTime,
                                       double rate, bool buffering, double sinceSeek) {
    return !buffering && (!std::isfinite(audioTime) ||
        (std::fabs(videoTime - audioTime) > std::max(2.0, rate) && sinceSeek > 0.8));
}

struct YTKACETranslationClock {
    double previousTime = NAN;
    double previousNow = NAN;
    double lastAdvance = -INFINITY;
    void reset() { previousTime = previousNow = NAN; lastAdvance = -INFINITY; }
    bool shouldPlay(double videoTime, double now, double rate = 1.0) {
        if (!std::isfinite(videoTime) || videoTime < 0) {
            reset(); return false;
        }
        double limit = std::isfinite(previousNow) && std::isfinite(rate)
            ? std::max(2.0, std::max(0.0, now - previousNow) * rate + 0.5) : 2.0;
        if (std::isfinite(previousTime) && videoTime > previousTime && videoTime - previousTime < limit)
            lastAdvance = now;
        else if (!std::isfinite(previousTime) || videoTime < previousTime || videoTime - previousTime >= limit)
            lastAdvance = -INFINITY;
        previousTime = videoTime;
        previousNow = now;
        // ponytail: clock progress detects buffering within 0.5s without private state enum values.
        return now - lastAdvance < 0.5;
    }
};
