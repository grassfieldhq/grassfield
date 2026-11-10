import QtQuick
import QtTest
import "../../ui/Grassfield/Ui/DisplayName.js" as DisplayName

// GF-105: the one helper every file name goes through before it is shown. The controls are built from code points so that this
// source never holds a bidi control itself.
TestCase {
    name: "DisplayName"

    function c(code) {
        return String.fromCharCode(code);
    }

    function test_bidiControlsAreWrittenOut() {
        compare(DisplayName.text("evil" + c(0x202E) + "fdp.exe"), "evil<U+202E>fdp.exe");
        compare(DisplayName.text("a" + c(0x2066) + "b" + c(0x2069) + "c"), "a<U+2066>b<U+2069>c");
        compare(DisplayName.text(c(0x202A) + c(0x202B) + c(0x202C) + c(0x202D)), "<U+202A><U+202B><U+202C><U+202D>");
        compare(DisplayName.text("a" + c(0x2067) + c(0x2068)), "a<U+2067><U+2068>");
    }

    // Files' fifth security check (V1): RLM + "pdf." + RLM + "Invoice" was drawn "Invoice.pdf"; the marks LRM, RLM and ALM are
    // written out like the embeddings, with four digits as FileLogic::displayName writes them.
    function test_bidiMarksAreWrittenOut() {
        compare(DisplayName.text(c(0x200F) + "pdf." + c(0x200F) + "Invoice"), "<U+200F>pdf.<U+200F>Invoice");
        compare(DisplayName.text(c(0x061C) + "pdf." + c(0x061C) + "Invoice"), "<U+061C>pdf.<U+061C>Invoice");
        compare(DisplayName.text(c(0x200F) + "jpg." + c(0x200F) + "Holiday"), "<U+200F>jpg.<U+200F>Holiday");
        compare(DisplayName.text("marks" + c(0x200E) + "shown" + c(0x200F)), "marks<U+200E>shown<U+200F>");
    }

    function test_lineAndParagraphSeparatorsAreWrittenOut() {
        compare(DisplayName.text("a" + c(0x2028) + "b" + c(0x2029) + "c"), "a<U+2028>b<U+2029>c");
    }

    function test_breaksBecomeTheReturnSymbol() {
        compare(DisplayName.text("two\nlines"), "two" + c(0x23CE) + "lines");
        compare(DisplayName.text("a\r\n\r\nb"), "a" + c(0x23CE) + "b");
    }

    function test_everythingElseStays() {
        compare(DisplayName.text("say \"hi\" \\ there"), "say \"hi\" \\ there");
        compare(DisplayName.text(c(0x05D0) + c(0x0628)), c(0x05D0) + c(0x0628), "right-to-left letters stay");
        compare(DisplayName.text("R" + c(0xE9) + "sum" + c(0xE9)), "R" + c(0xE9) + "sum" + c(0xE9));
        compare(DisplayName.text(undefined), "");
        compare(DisplayName.text(null), "");
        compare(DisplayName.text(12), "12");
    }
}
