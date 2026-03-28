// ANSIStyle.swift
// ANSI escape 코드, 컬러, 박스 드로잉
// tty 감지: isatty(STDERR_FILENO)로 비터미널 환경에서 자동 비활성화

import Foundation

/// ANSI 스타일 코드
/// 비TTY 환경에서는 빈 문자열 반환하여 컬러/스타일 자동 비활성화
nonisolated enum ANSIStyle {

    /// stderr tty 여부 — isatty(STDERR_FILENO) 기준 (진행 상황 출력용)
    static var isTTY: Bool {
        return isatty(STDERR_FILENO) != 0
    }

    /// stdout tty 여부 — isatty(STDOUT_FILENO) 기준 (결과 출력 컬러 적용용)
    static var isStdoutTTY: Bool {
        return isatty(STDOUT_FILENO) != 0
    }

    // MARK: - 색상

    /// 초록색 (성공)
    static var green: String { isTTY ? "\u{001b}[32m" : "" }
    /// 빨간색 (에러)
    static var red: String { isTTY ? "\u{001b}[31m" : "" }
    /// 파란색 (정보)
    static var blue: String { isTTY ? "\u{001b}[34m" : "" }
    /// 노란색 (경고)
    static var yellow: String { isTTY ? "\u{001b}[33m" : "" }
    /// 청록색 (강조)
    static var cyan: String { isTTY ? "\u{001b}[36m" : "" }
    /// 흰색
    static var white: String { isTTY ? "\u{001b}[37m" : "" }

    // MARK: - 스타일

    /// 굵게
    static var bold: String { isTTY ? "\u{001b}[1m" : "" }
    /// 어둡게
    static var dim: String { isTTY ? "\u{001b}[2m" : "" }
    /// 이탤릭
    static var italic: String { isTTY ? "\u{001b}[3m" : "" }
    /// 밑줄
    static var underline: String { isTTY ? "\u{001b}[4m" : "" }
    /// 반전 (배경/전경 교환)
    static var reversed: String { isTTY ? "\u{001b}[7m" : "" }

    // MARK: - 리셋

    /// 모든 스타일 초기화
    static var reset: String { isTTY ? "\u{001b}[0m" : "" }

    // MARK: - 커서 제어

    /// 커서 위로 N줄 이동
    static func cursorUp(_ n: Int) -> String { isTTY ? "\u{001b}[\(n)A" : "" }
    /// 줄 지우기
    static var eraseLine: String { isTTY ? "\u{001b}[2K\r" : "" }
    /// 커서 숨기기
    static var hideCursor: String { isTTY ? "\u{001b}[?25l" : "" }
    /// 커서 보이기
    static var showCursor: String { isTTY ? "\u{001b}[?25h" : "" }

    // MARK: - 박스 드로잉

    /// 상단 왼쪽 모서리
    static let boxTopLeft = "╭"
    /// 상단 오른쪽 모서리
    static let boxTopRight = "╮"
    /// 하단 왼쪽 모서리
    static let boxBottomLeft = "╰"
    /// 하단 오른쪽 모서리
    static let boxBottomRight = "╯"
    /// 가로선
    static let boxHorizontal = "─"
    /// 세로선
    static let boxVertical = "│"

    /// 박스 그리기
    static func box(title: String, content: [String], width: Int = 50) -> String {
        guard isTTY else {
            // 비TTY 환경에서는 심플 텍스트
            var result = "=== \(title) ===\n"
            for line in content {
                result += "  \(line)\n"
            }
            return result
        }

        let innerWidth = width - 2
        let titlePadded = " \(title) "
        let topLine = boxTopLeft + titlePadded + String(repeating: boxHorizontal, count: max(0, innerWidth - titlePadded.count)) + boxTopRight

        var result = cyan + topLine + reset + "\n"
        for line in content {
            let truncated = String(line.prefix(innerWidth))
            let padding = String(repeating: " ", count: max(0, innerWidth - truncated.count))
            result += cyan + boxVertical + reset + " \(truncated)\(padding)" + cyan + boxVertical + reset + "\n"
        }
        result += cyan + boxBottomLeft + String(repeating: boxHorizontal, count: innerWidth) + boxBottomRight + reset + "\n"
        return result
    }

    // MARK: - 배경색

    /// 배경 강조 (선택 항목용)
    static var highlighted: String { isTTY ? "\u{001b}[7m" : "" }
}
