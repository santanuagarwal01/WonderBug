//
//  Colors.swift
//  WonderBug
//
//  Created by Santanu Agarwal on 08/07/26.
//

import SwiftUI

/// WonderBug brand palette ("wb" prefix): cream background, dark gray-green text, sage accent
/// used for borders/buttons/tab highlights, plus soft chip and beige fills.
extension Color {
    
    static let wbBackground = Color(
        red: 249/255,
        green: 246/255,
        blue: 240/255
    )
    
    static let wbTitle = Color(
        red: 74/255,
        green: 78/255,
        blue: 77/255
    )
    
    static let wbBorder = Color(
        red: 143/255,
        green: 180/255,
        blue: 171/255
    )
    
    static let wbChip = Color(
        red: 231/255,
        green: 243/255,
        blue: 240/255
    )
    
    static let wbButton = Color(
        red: 240/255,
        green: 235/255,
        blue: 225/255
    )
}
