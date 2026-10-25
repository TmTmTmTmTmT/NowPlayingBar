import CoreGraphics
import Testing
@testable import FloatingLyric

@Suite struct LyricHDRTests {
    @Test func lightAppearanceIsSDR() {
        #expect(LyricHDR.headroom(isDark: false, potential: 16, target: 1.6) == nil)
    }

    @Test func noEDRScreenIsSDR() {
        #expect(LyricHDR.headroom(isDark: true, potential: 1.0, target: 1.6) == nil)
        #expect(LyricHDR.headroom(isDark: true, potential: .nan, target: 1.6) == nil)
    }

    @Test func headroomIsCappedByPotential() {
        #expect(LyricHDR.headroom(isDark: true, potential: 1.3, target: 1.6) == 1.3)
        #expect(LyricHDR.headroom(isDark: true, potential: 16, target: 1.6) == 1.6)
    }

    @Test func colorKeepsComponentsAndAlpha() throws {
        let c = try #require(LyricHDR.color(white: 1.03, headroom: 1.6, alpha: 0.5))
        #expect(c.alpha == 0.5)
        let comps = try #require(c.components)
        #expect(abs(comps[0] - 1.03) < 1e-6 && abs(comps[1] - 1.03) < 1e-6)
        #expect(LyricHDR.color(white: .nan, headroom: 1.8) == nil)
    }

    @Test func baseAndPeakValues() {
        #expect(LyricHDR.Metrics.fillMultiplier == 1.03)
        #expect(LyricHDR.baseValue(headroom: 16) == 1.03)
        #expect(LyricHDR.baseValue(headroom: 1.02) == 1.02)
        #expect(LyricHDR.peakValue(strength: 0, headroom: 16) == 1.15)
        #expect(LyricHDR.peakValue(strength: 1, headroom: 16) == 1.6)
        #expect(abs(LyricHDR.peakValue(strength: 0.5, headroom: 16) - 1.375) < 1e-9)
        #expect(LyricHDR.peakValue(strength: 1, headroom: 1.2) == 1.2)       // potential clamp
        #expect(LyricHDR.peakValue(strength: .nan, headroom: 16) == 1.15)
    }

    @Test func levelFollowsProgressAndQuantizes() {
        #expect(LyricHDR.level(progress: 0, strength: 1, headroom: 16) == 1.03)
        #expect(LyricHDR.level(progress: 1, strength: 1, headroom: 16) == 1.6)
        #expect(LyricHDR.level(progress: 1, strength: 0, headroom: 16) == 1.15)
        #expect(LyricHDR.level(progress: 0.5, strength: 1, headroom: 16) == 1.32)   // 1.315 -> 0.01 steps
        #expect(LyricHDR.level(progress: 1, strength: 1, headroom: 1.1) == 1.1)
        #expect(LyricHDR.level(progress: .nan, strength: 1, headroom: 16) == 1.03)
    }

    @Test func modeValues() {
        #expect(LyricHDR.Mode.standard.base == 1.03 && LyricHDR.Mode.standard.peakMin == 1.15 && LyricHDR.Mode.standard.peakMax == 1.6)
        #expect(LyricHDR.Mode.plainClear.base == 1.35 && LyricHDR.Mode.plainClear.peakMin == 1.5 && LyricHDR.Mode.plainClear.peakMax == 2.0)
        #expect(LyricHDR.Mode.clearFrost.base == 1.10 && LyricHDR.Mode.clearFrost.peakMin == 1.25 && LyricHDR.Mode.clearFrost.peakMax == 1.7)
        #expect(LyricHDR.level(progress: 1, strength: 1, headroom: 16, mode: .clearFrost) == 1.7)
        #expect(LyricHDR.level(progress: 0, strength: 1, headroom: 16, mode: .clearFrost) == 1.1)
        #expect(LyricHDR.headroom(isDark: true, potential: 1.5, target: LyricHDR.Mode.clearFrost.peakMax) == 1.5)
        let m = LyricHDR.Mode.plainClear
        #expect(LyricHDR.baseValue(headroom: 16, mode: m) == 1.35)
        #expect(LyricHDR.peakValue(strength: 0, headroom: 16, mode: m) == 1.5)
        #expect(LyricHDR.peakValue(strength: 1, headroom: 16, mode: m) == 2.0)
        #expect(abs(LyricHDR.peakValue(strength: 0.5, headroom: 16, mode: m) - 1.75) < 1e-9)
        #expect(LyricHDR.level(progress: 0, strength: 1, headroom: 16, mode: m) == 1.35)
        #expect(LyricHDR.level(progress: 1, strength: 1, headroom: 16, mode: m) == 2.0)
        #expect(LyricHDR.level(progress: 1, strength: 0, headroom: 16, mode: m) == 1.5)
    }

    @Test func modeValuesAreClampedByPotential() {
        let m = LyricHDR.Mode.plainClear
        #expect(LyricHDR.baseValue(headroom: 1.1, mode: m) == 1.1)
        #expect(LyricHDR.peakValue(strength: 1, headroom: 1.5, mode: m) == 1.5)
        #expect(LyricHDR.level(progress: 1, strength: 1, headroom: 1.3, mode: m) == 1.3)
        #expect(LyricHDR.level(progress: 0, strength: 1, headroom: 1.3, mode: m) == 1.3)
        // The host asks for the mode's peakMax and the screen's potential caps it.
        #expect(LyricHDR.headroom(isDark: true, potential: 16, target: m.peakMax) == 2.0)
        #expect(LyricHDR.headroom(isDark: true, potential: 1.6, target: m.peakMax) == 1.6)
        #expect(LyricHDR.headroom(isDark: false, potential: 16, target: m.peakMax) == nil)
        // The default argument keeps the standard values.
        #expect(LyricHDR.baseValue(headroom: 16) == LyricHDR.baseValue(headroom: 16, mode: .standard))
    }
}
