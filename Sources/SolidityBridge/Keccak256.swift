import Foundation

enum Keccak256 {
    private static let rotations = [
        0, 1, 62, 28, 27,
        36, 44, 6, 55, 20,
        3, 10, 43, 25, 39,
        41, 45, 15, 21, 8,
        18, 2, 61, 56, 14
    ]
    private static let roundConstants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
        0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
        0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
    ]

    static func hash(_ data: Data) -> Data {
        let rate = 136
        var state = [UInt64](repeating: 0, count: 25)
        var position = 0
        for byte in data {
            state[position / 8] ^= UInt64(byte) << ((position % 8) * 8)
            position += 1
            if position == rate {
                permute(&state)
                position = 0
            }
        }
        state[position / 8] ^= 1 << ((position % 8) * 8)
        state[rate / 8 - 1] ^= 0x8000000000000000
        permute(&state)
        return Data((0..<32).map { UInt8(truncatingIfNeeded: state[$0 / 8] >> (($0 % 8) * 8)) })
    }

    private static func permute(_ state: inout [UInt64]) {
        var columns = [UInt64](repeating: 0, count: 5)
        var rotated = [UInt64](repeating: 0, count: 25)
        for roundConstant in roundConstants {
            for x in 0..<5 {
                columns[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
            }
            for x in 0..<5 {
                let delta = columns[(x + 4) % 5] ^ rotate(columns[(x + 1) % 5], by: 1)
                for y in 0..<5 {
                    let index = x + 5 * y
                    state[index] ^= delta
                    rotated[y + 5 * ((2 * x + 3 * y) % 5)] = rotate(state[index], by: rotations[index])
                }
            }
            for y in stride(from: 0, to: 25, by: 5) {
                for x in 0..<5 {
                    state[y + x] = rotated[y + x] ^ (~rotated[y + (x + 1) % 5] & rotated[y + (x + 2) % 5])
                }
            }
            state[0] ^= roundConstant
        }
    }

    private static func rotate(_ lane: UInt64, by bits: Int) -> UInt64 {
        (lane << bits) | (lane >> (64 - bits))
    }
}
