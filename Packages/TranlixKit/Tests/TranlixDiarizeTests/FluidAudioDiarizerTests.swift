import Testing

@testable import TranlixDiarize

/// The settings the real model runs with, checked without loading it.
@Suite("FluidAudioDiarizer settings")
struct FluidAudioDiarizerTests {
    @Test("VBx keeps distinct voices apart instead of merging them")
    func clusteringSettings() {
        let clustering = FluidAudioDiarizer.configuration.clustering

        // pyannote's default Fb of 0.8 merged three clearly separate voices into one on a
        // 39-minute meeting whose first clustering pass had found all three. 0.3 kept them
        // apart there and did not lose a speaker on any other recording it was tried on.
        #expect(clustering.warmStartFb == 0.3)
        #expect(clustering.warmStartFa == 0.07)
        #expect(clustering.threshold == 0.6)
    }

    @Test("the configuration id changes with the clustering settings")
    func configurationIDFollowsSettings() {
        let current = FluidAudioDiarizer.configuration
        var changed = current
        changed.Fb = 0.5

        #expect(
            FluidAudioDiarizer.configurationID(for: changed)
                != FluidAudioDiarizer.configurationID(for: current)
        )
        #expect(
            FluidAudioDiarizer().configurationID
                == FluidAudioDiarizer.configurationID(for: current)
        )
    }
}
