//
//  tools.swift
//  CMORE
//
//  Created by ZIQIANG ZHU on 3/24/26.
//

nonisolated func dprint(_ message: String) {
    #if DEBUG
    print(message)
    #endif
}
