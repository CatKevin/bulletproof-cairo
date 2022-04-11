from common_ec_cairo.ec.ec import EcPoint

struct TranscriptEntry:
    member L: EcPoint
    member R: EcPoint
    member x: felt
end

struct Transcript:
    member transcript_seed: felt
    member n_rounds: felt
    member transcript_entries: TranscriptEntry*
end


# Represents the proof passed to the verifier
# not including the transcript entries
struct ProofInnerproduct2:
    member a: felt
    member b: felt
end