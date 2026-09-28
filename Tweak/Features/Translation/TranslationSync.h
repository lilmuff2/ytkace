#pragma once
#include <cmath>

struct YTKACETranslationClock {
    double previousTime = NAN;
    double lastAdvance = -INFINITY;
    void reset() { previousTime = NAN; lastAdvance = -INFINITY; }
    bool shouldPlay(double videoTime, double now) {
        if (!std::isfinite(videoTime) || videoTime < 0) {
            reset(); return false;
        }
        if (std::isfinite(previousTime) && videoTime > previousTime && videoTime - previousTime < 2.0)
            lastAdvance = now;
        else if (!std::isfinite(previousTime) || videoTime < previousTime || videoTime - previousTime >= 2.0)
            lastAdvance = -INFINITY;
        previousTime = videoTime;
        // ponytail: clock progress detects buffering within 0.5s without private state enum values.
        return now - lastAdvance < 0.5;
    }
};
