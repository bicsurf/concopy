import AppKit
import ConCopyCore
import SwiftUI

/// Sistema di Design e Palette Colori Nativa per ConCopy (macOS Sequoia / Sonoma).
/// Ispirato ai principi di "Impeccable" e dell'Human Interface Guidelines:
/// - Grafiti profondi e grigi neutri privi di saturazione eccessiva per gli sfondi;
/// - Accento caldo "Artisan Terracotta" per focus ed elementi primari;
/// - Oro caldo per i preferiti;
/// - Supporto nativo dinamico Light / Dark Mode tramite NSColor(dynamicProvider:).
public enum ConCopyTheme {

    // MARK: - Dynamic Color Helper
    public static func dynamicColor(
        light: NSColor,
        dark: NSColor
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua ? dark : light
        })
    }

    // MARK: - Superfici e Bordi (Surfaces & Borders)
    public enum Surfaces {
        /// Tinta di fondo della finestra HUD (grigio ardesia/grafite calibrato per staccare su sfondi bianchi)
        public static let windowBackgroundTint = ConCopyTheme.dynamicColor(
            light: NSColor(white: 0.88, alpha: 0.94),
            dark: NSColor(white: 0.11, alpha: 0.90)
        )

        /// Bordo perimetrale della finestra HUD (più definito in light mode per staccare su sfondi chiari)
        public static let windowBorder = ConCopyTheme.dynamicColor(
            light: NSColor.black.withAlphaComponent(0.24),
            dark: NSColor.white.withAlphaComponent(0.14)
        )

        /// Maniglia di trascinamento superiore
        public static let dragHandle = ConCopyTheme.dynamicColor(
            light: NSColor.black.withAlphaComponent(0.38),
            dark: NSColor.white.withAlphaComponent(0.24)
        )

        /// Sfondo pill e selettori secondari (più scuro in light mode per maggiore contrasto)
        public static let pillBackground = ConCopyTheme.dynamicColor(
            light: NSColor.black.withAlphaComponent(0.09),
            dark: NSColor.white.withAlphaComponent(0.07)
        )

        /// Bordo pill e divisori interni
        public static let pillBorder = ConCopyTheme.dynamicColor(
            light: NSColor.black.withAlphaComponent(0.18),
            dark: NSColor.white.withAlphaComponent(0.10)
        )

        /// Separatore orizzontale/verticale
        public static let divider = ConCopyTheme.dynamicColor(
            light: NSColor.black.withAlphaComponent(0.20),
            dark: NSColor.white.withAlphaComponent(0.12)
        )

        /// Sfondo barra batch / footer
        public static let footerBackground = ConCopyTheme.dynamicColor(
            light: NSColor(white: 0.84, alpha: 0.95),
            dark: NSColor(white: 0.12, alpha: 0.70)
        )
    }

    // MARK: - Righe e Stati di Selezione (Rows & Selection)
    public enum Rows {
        /// Sfondo della riga selezionata (calibrato con maggior contrasto in light mode)
        public static let selectedBackground = ConCopyTheme.dynamicColor(
            light: NSColor(red: 0.80, green: 0.35, blue: 0.18, alpha: 0.22),
            dark: NSColor(red: 0.90, green: 0.46, blue: 0.30, alpha: 0.20)
        )

        /// Bordo della riga selezionata (bordo netto e visibile)
        public static let selectedBorder = ConCopyTheme.dynamicColor(
            light: NSColor(red: 0.74, green: 0.28, blue: 0.12, alpha: 0.60),
            dark: NSColor(red: 0.90, green: 0.46, blue: 0.30, alpha: 0.45)
        )

        /// Sfondo riga in hover (non selezionata)
        public static let hoverBackground = ConCopyTheme.dynamicColor(
            light: NSColor.black.withAlphaComponent(0.05),
            dark: NSColor.white.withAlphaComponent(0.05)
        )

        /// Sfondo riga in multi-selezione (batch)
        public static let batchSelectedBackground = ConCopyTheme.dynamicColor(
            light: NSColor(red: 0.80, green: 0.35, blue: 0.18, alpha: 0.34),
            dark: NSColor(red: 0.90, green: 0.46, blue: 0.30, alpha: 0.32)
        )
    }

    // MARK: - Accenti e Stati Funzionali (Accents & Brand)
    public enum Accents {
        /// Accento Primario ConCopy: Artisan Terracotta (caldo, profondo e conforme a WCAG AA in light mode)
        public static let primary = ConCopyTheme.dynamicColor(
            light: NSColor(red: 0.72, green: 0.28, blue: 0.12, alpha: 1.0),
            dark: NSColor(red: 0.92, green: 0.48, blue: 0.32, alpha: 1.0)
        )

        /// Stella dei Preferiti (Warm Radiant Amber / Gold)
        public static let star = ConCopyTheme.dynamicColor(
            light: NSColor(red: 0.80, green: 0.48, blue: 0.06, alpha: 1.0),
            dark: NSColor(red: 0.98, green: 0.68, blue: 0.18, alpha: 1.0)
        )

        /// Sfondo aureola per i preferiti
        public static let starBackground = ConCopyTheme.dynamicColor(
            light: NSColor(red: 0.80, green: 0.48, blue: 0.06, alpha: 0.18),
            dark: NSColor(red: 0.98, green: 0.68, blue: 0.18, alpha: 0.20)
        )

        /// Badge Modalità Solo Testo attiva
        public static let plainTextActive = ConCopyTheme.dynamicColor(
            light: NSColor(red: 0.72, green: 0.28, blue: 0.12, alpha: 1.0),
            dark: NSColor(red: 0.92, green: 0.48, blue: 0.32, alpha: 1.0)
        )

        /// Icona e accento Snippet (Ambra caldo #FF9F0A)
        public static let snippet = ConCopyTheme.dynamicColor(
            light: NSColor(red: 0.88, green: 0.52, blue: 0.05, alpha: 1.0),
            dark: NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1.0)
        )
        public static let snippetBackground = ConCopyTheme.dynamicColor(
            light: NSColor(red: 0.88, green: 0.52, blue: 0.05, alpha: 0.14),
            dark: NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 0.18)
        )
    }

    // MARK: - Badge Scorciatoie (Quick Paste & Navigation Badges)
    public enum Badges {
        /// Sfondo del pill badge per Quick Paste (⌘1..⌘0)
        public static func quickPasteBackground(isSelected: Bool) -> Color {
            if isSelected {
                return ConCopyTheme.dynamicColor(
                    light: NSColor(red: 0.78, green: 0.32, blue: 0.16, alpha: 0.28),
                    dark: NSColor(red: 0.92, green: 0.48, blue: 0.32, alpha: 0.26)
                )
            } else {
                return ConCopyTheme.dynamicColor(
                    light: NSColor.black.withAlphaComponent(0.07),
                    dark: NSColor.white.withAlphaComponent(0.08)
                )
            }
        }

        /// Bordo del pill badge per Quick Paste
        public static func quickPasteBorder(isSelected: Bool) -> Color {
            if isSelected {
                return ConCopyTheme.dynamicColor(
                    light: NSColor(red: 0.72, green: 0.28, blue: 0.12, alpha: 0.65),
                    dark: NSColor(red: 0.92, green: 0.48, blue: 0.32, alpha: 0.50)
                )
            } else {
                return ConCopyTheme.dynamicColor(
                    light: NSColor.black.withAlphaComponent(0.16),
                    dark: NSColor.white.withAlphaComponent(0.12)
                )
            }
        }

        /// Colore del testo/glifo per Quick Paste (nero/carbone ad alto contrasto in light mode)
        public static func quickPasteForeground(isSelected: Bool) -> Color {
            if isSelected {
                return ConCopyTheme.dynamicColor(
                    light: NSColor(red: 0.60, green: 0.18, blue: 0.06, alpha: 1.0),
                    dark: NSColor(red: 0.95, green: 0.58, blue: 0.42, alpha: 1.0)
                )
            } else {
                return ConCopyTheme.dynamicColor(
                    light: NSColor(white: 0.15, alpha: 1.0),
                    dark: NSColor(white: 0.78, alpha: 1.0)
                )
            }
        }

        /// Badge scorciatoia per schede liste (⌥1..⌥9)
        public static func tabShortcutBackground(isSelected: Bool) -> Color {
            if isSelected {
                return ConCopyTheme.dynamicColor(
                    light: NSColor(red: 0.78, green: 0.32, blue: 0.16, alpha: 0.24),
                    dark: NSColor(red: 0.92, green: 0.48, blue: 0.32, alpha: 0.24)
                )
            } else {
                return ConCopyTheme.dynamicColor(
                    light: NSColor.black.withAlphaComponent(0.06),
                    dark: NSColor.white.withAlphaComponent(0.07)
                )
            }
        }
    }

    // MARK: - Tipologie di Clip (Type Pills & Icons)
    public enum Types {
        public static func background(for type: ClipPrimaryType) -> Color {
            switch type {
            case .text:
                return ConCopyTheme.dynamicColor(
                    light: NSColor(red: 0.15, green: 0.40, blue: 0.75, alpha: 0.15),
                    dark: NSColor(red: 0.35, green: 0.60, blue: 0.90, alpha: 0.16)
                )
            case .richText:
                return ConCopyTheme.dynamicColor(
                    light: NSColor(red: 0.32, green: 0.26, blue: 0.75, alpha: 0.15),
                    dark: NSColor(red: 0.52, green: 0.46, blue: 0.90, alpha: 0.16)
                )
            case .html:
                return ConCopyTheme.dynamicColor(
                    light: NSColor(red: 0.50, green: 0.20, blue: 0.70, alpha: 0.15),
                    dark: NSColor(red: 0.70, green: 0.40, blue: 0.85, alpha: 0.16)
                )
            case .image:
                return ConCopyTheme.dynamicColor(
                    light: NSColor(red: 0.10, green: 0.55, blue: 0.50, alpha: 0.15),
                    dark: NSColor(red: 0.25, green: 0.75, blue: 0.70, alpha: 0.16)
                )
            case .file:
                return ConCopyTheme.dynamicColor(
                    light: NSColor(red: 0.70, green: 0.40, blue: 0.10, alpha: 0.15),
                    dark: NSColor(red: 0.90, green: 0.60, blue: 0.25, alpha: 0.16)
                )
            case .url:
                return ConCopyTheme.dynamicColor(
                    light: NSColor(red: 0.10, green: 0.50, blue: 0.80, alpha: 0.15),
                    dark: NSColor(red: 0.30, green: 0.70, blue: 0.95, alpha: 0.16)
                )
            case .color:
                return ConCopyTheme.dynamicColor(
                    light: NSColor(red: 0.75, green: 0.20, blue: 0.45, alpha: 0.15),
                    dark: NSColor(red: 0.92, green: 0.40, blue: 0.65, alpha: 0.16)
                )
            }
        }

        public static func foreground(for type: ClipPrimaryType) -> Color {
            switch type {
            case .text:
                return ConCopyTheme.dynamicColor(
                    light: NSColor(red: 0.08, green: 0.30, blue: 0.68, alpha: 1.0),
                    dark: NSColor(red: 0.45, green: 0.70, blue: 0.95, alpha: 1.0)
                )
            case .richText:
                return ConCopyTheme.dynamicColor(
                    light: NSColor(red: 0.22, green: 0.16, blue: 0.62, alpha: 1.0),
                    dark: NSColor(red: 0.60, green: 0.54, blue: 0.95, alpha: 1.0)
                )
            case .html:
                return ConCopyTheme.dynamicColor(
                    light: NSColor(red: 0.40, green: 0.12, blue: 0.58, alpha: 1.0),
                    dark: NSColor(red: 0.78, green: 0.45, blue: 0.92, alpha: 1.0)
                )
            case .image:
                return ConCopyTheme.dynamicColor(
                    light: NSColor(red: 0.06, green: 0.42, blue: 0.38, alpha: 1.0),
                    dark: NSColor(red: 0.30, green: 0.80, blue: 0.75, alpha: 1.0)
                )
            case .file:
                return ConCopyTheme.dynamicColor(
                    light: NSColor(red: 0.58, green: 0.30, blue: 0.04, alpha: 1.0),
                    dark: NSColor(red: 0.95, green: 0.65, blue: 0.30, alpha: 1.0)
                )
            case .url:
                return ConCopyTheme.dynamicColor(
                    light: NSColor(red: 0.06, green: 0.38, blue: 0.68, alpha: 1.0),
                    dark: NSColor(red: 0.35, green: 0.75, blue: 0.98, alpha: 1.0)
                )
            case .color:
                return ConCopyTheme.dynamicColor(
                    light: NSColor(red: 0.65, green: 0.12, blue: 0.38, alpha: 1.0),
                    dark: NSColor(red: 0.95, green: 0.45, blue: 0.70, alpha: 1.0)
                )
            }
        }
    }
}
