//
// TargetZone.swift
// CMORE
//
// Created by QUYEN TAN on 10/9/26.
//
import Vision

nonisolated struct TargetZone: Codable, Sendable {
    let topLeft: Keypoint
    let topRight: Keypoint
    let bottomRight: Keypoint
    let bottomLeft: Keypoint
}
