package org.worldbank.suso;

/** Converts ignored Stata SFI return codes into an actionable Java failure. */
final class SfiCheck {
    private SfiCheck() {}

    static void ok(int rc) {
        if (rc != 0) throw new IllegalStateException("Stata SFI call failed (rc=" + rc + ")");
    }
}
