// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

let TPPasteboardTransferNameKey = "TPPasteboardTransferName"
let TPPasteboardTransferChangeCountKey = "TPPasteboardTransferChangeCount"

func TPTypeNeedsSwapping(_ type: String) -> Bool {
    if CFByteOrderGetCurrent() == Int(CFByteOrderBigEndian.rawValue) {
        return false
    } else {
        return type == "public.utf16-plain-text" || type == "CorePasteboardFlavorType 0x75747874"
    }
}

func TPTypeNeedsIgnoring(_ type: String) -> Bool {
    return type == "com.apple.txn.text-multimedia-data" || type == "CorePasteboardFlavorType 0x7478746E"
}
