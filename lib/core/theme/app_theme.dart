import 'package:flutter/material.dart';

/// 5BIRR Design System — inspired by the Ethiopian 5 Birr note.
/// Primary: deep green, Secondary: teal, Background: cream/off-white.
class AppTheme {
  AppTheme._();

  // ── Brand Colors ──────────────────────────────────────────────
  static const Color primaryGreen = Color(0xFF1B5E20);
  static const Color primaryGreenLight = Color(0xFF388E3C);
  static const Color primaryGreenDark = Color(0xFF0D3B12);
  static const Color teal = Color(0xFF00897B);
  static const Color tealLight = Color(0xFF4DB6AC);
  static const Color cream = Color(0xFFF5F1E8);
  static const Color creamDark = Color(0xFFE8E0D0);
  static const Color gold = Color(0xFFC6A832);
  static const Color goldLight = Color(0xFFE0C850);

  // ── Semantic Colors ───────────────────────────────────────────
  static const Color success = Color(0xFF2E7D32);
  static const Color warning = Color(0xFFF9A825);
  static const Color error = Color(0xFFC62828);
  static const Color info = Color(0xFF1565C0);

  // ── Text Colors ───────────────────────────────────────────────
  static const Color textPrimary = Color(0xFF1A1A1A);
  static const Color textSecondary = Color(0xFF5A5A5A);
  static const Color textMuted = Color(0xFF8A8A8A);
  static const Color textOnPrimary = Colors.white;

  // ── Surface Colors ────────────────────────────────────────────
  // Light-green lightening of the primary green: soft surfaces instead of
  // white, so the login and signup pages stop looking flat and cheap.
  static const Color lightGreen = Color(0xFFE8F5E9);
  static const Color lightGreenSurface = Color(0xFFC8E6C9);

  // Light lemon: a warm cream-lemon tint used on auth cards and overlays.
  // It replaces the flat white parts of the login/signup screens so those
  // screens read as warm and on-brand rather than stark white blocks.
  // Palette: pale backdrop 0xFBF7EE, card fill 0xF6EFD9, stronger tint
  // 0xF1E2B8 for accents only. All three stay light enough for dark text
  // (textPrimary on lightLemonSurface is ~10:1).
  static const Color lightLemonPale = Color(0xFFFBF7EE);
  static const Color lightLemonSurface = Color(0xFFF6EFD9);
  static const Color lightLemonAccent = Color(0xFFF1E2B8);

  static const Color surface = Colors.white;
  static const Color surfaceVariant = Color(0xFFF8F6F2);
  static const Color background = cream;
  static const Color cardBorder = Color(0xFFE0D8C8);

  // ── Typography scale ─────────────────────────────────────────
  //
  // One place defines every text style in the app so headings, body,
  // captions and buttons stay consistent from login through every screen.
  // UI text should reference these (or the small set of inline styles that
  // match them) instead of ad-hoc sizes.

  /// Page titles on auth/onboarding headers (Login, Registration).
  static const TextStyle display = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    color: textPrimary,
    height: 1.2,
    letterSpacing: -0.5,
  );

  /// Screen titles and major section titles.
  static const TextStyle headingLarge = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w700,
    color: textPrimary,
    height: 1.3,
  );

  /// Card titles and sub-section headings.
  static const TextStyle heading = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    color: textPrimary,
    height: 1.3,
  );

  /// In-form group headings (e.g. "Personal Information").
  static const TextStyle sectionHeader = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    color: textPrimary,
    letterSpacing: 0.2,
  );

  /// Emphasised body text (list titles, detail values).
  static const TextStyle bodyStrong = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: textPrimary,
    height: 1.45,
  );

  /// Default body text.
  static const TextStyle bodyLarge = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    color: textPrimary,
    height: 1.5,
  );

  /// Secondary body text (slightly smaller, softer).
  static const TextStyle bodyMedium = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: textSecondary,
    height: 1.5,
  );

  /// Small helper text under labels/fields.
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: textMuted,
    height: 1.4,
  );

  /// Tiny meta text (timestamps, footnotes).
  static const TextStyle micro = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    color: textMuted,
    height: 1.4,
  );

  /// Numeric emphasis (prices, balances) — tabular feel via letterSpacing.
  static const TextStyle price = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    color: textPrimary,
    letterSpacing: 0.2,
  );

  // ── Light Theme ───────────────────────────────────────────────
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.light(
        primary: primaryGreen,
        onPrimary: textOnPrimary,
        secondary: teal,
        onSecondary: textOnPrimary,
        surface: surface,
        onSurface: textPrimary,
        error: error,
        onError: textOnPrimary,
      ),
      scaffoldBackgroundColor: background,
      appBarTheme: const AppBarTheme(
        backgroundColor: primaryGreen,
        foregroundColor: textOnPrimary,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: textOnPrimary,
          letterSpacing: 0.3,
        ),
      ),
      textTheme: const TextTheme(
        // Theme-level defaults: any Text widget without an explicit style
        // inherits a coherent size/weight/height from here.
        displayLarge: display,
        headlineMedium: headingLarge,
        titleLarge: heading,
        titleMedium: sectionHeader,
        titleSmall: bodyStrong,
        bodyLarge: bodyLarge,
        bodyMedium: bodyMedium,
        bodySmall: caption,
        labelSmall: micro,
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: cardBorder, width: 0.5),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryGreen,
          foregroundColor: textOnPrimary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryGreen,
          side: const BorderSide(color: primaryGreen, width: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primaryGreen,
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: cardBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: cardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: primaryGreen, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: error),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        labelStyle: const TextStyle(color: textSecondary),
        hintStyle: const TextStyle(color: textMuted),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: primaryGreen,
        unselectedItemColor: textMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: creamDark,
        selectedColor: primaryGreen,
        // The colour is stated rather than left to inheritance. A chipTheme
        // labelStyle with no colour made every chip that did not set its own
        // take its text colour from whatever DefaultTextStyle surrounded it,
        // which is how a cream chip ended up with a label nobody could read.
        // textPrimary on creamDark is ~11:1. Chips that want a light label on
        // a dark fill (the subcategory chips) state both and override this.
        labelStyle: const TextStyle(fontSize: 12, color: textPrimary),
        // secondaryLabelStyle is deliberately NOT set here. In Material 3 it
        // governs the SELECTED state of selectable chips, and several admin /
        // provider filter chips select with a pale green tint and an explicit
        // dark label; overriding it would put a light label on that tint.
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      dividerTheme: const DividerThemeData(
        color: cardBorder,
        thickness: 0.5,
        space: 1,
      ),
    );
  }

  // ── Dark Theme ────────────────────────────────────────────────
  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary: tealLight,
        onPrimary: textPrimary,
        secondary: teal,
        onSecondary: textOnPrimary,
        surface: const Color(0xFF1E1E1E),
        onSurface: Colors.white,
        error: error,
      ),
      scaffoldBackgroundColor: const Color(0xFF121212),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1B5E20),
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF1E1E1E),
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  // ── Ethiopian Pattern Decoration ──────────────────────────────
  static BoxDecoration get ethiopianPatternDecoration {
    return const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [primaryGreen, primaryGreenDark],
      ),
    );
  }

  static BoxDecoration get cardDecoration {
    return BoxDecoration(
      color: surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: cardBorder, width: 0.5),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.04),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }
}
