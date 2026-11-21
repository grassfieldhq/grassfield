import QtQuick
import QtTest
import "../../shell/search/Calc.js" as Calc

TestCase {
    name: "SearchCalc"

    function ev(s) {
        const r = Calc.evaluate(s);
        return r.ok ? r.value : null;
    }

    function test_arithmetic() {
        compare(ev("2*(3+4)^2"), 98);
        compare(ev("1+2*3"), 7);
        compare(ev("10/4"), 2.5);
        compare(ev("10 % 4"), 2);
        compare(ev("2^3^2"), 512);
        compare(ev("-2^2"), -4);
        compare(ev("(1+2)*(3+4)"), 21);
        compare(ev("1.5+.5"), 2);
        compare(ev("--3"), 3);
        compare(ev("1e3+1"), 1001);
    }

    function test_percentAndConstants() {
        compare(ev("50%"), 0.5);
        compare(ev("200*(10%)"), 20);
        fuzzyCompare(ev("pi"), Math.PI, 1e-12);
        fuzzyCompare(ev("2*pi"), 2 * Math.PI, 1e-12);
        fuzzyCompare(ev("e"), Math.E, 1e-12);
    }

    function test_functions() {
        compare(ev("sqrt(16)"), 4);
        compare(ev("sin(0)"), 0);
        compare(ev("cos(0)"), 1);
        compare(ev("tan(0)"), 0);
        compare(ev("ln(e)"), 1);
        compare(ev("log(1000)"), 3);
        compare(ev("SQRT(9)+1"), 4);
    }

    function test_invalid() {
        compare(ev(""), null);
        compare(ev("1+"), null);
        compare(ev("(1+2"), null);
        compare(ev("1+2)"), null);
        compare(ev("1/0"), null);
        compare(ev("sqrt(-1)"), null);
        compare(ev("sqrt 4"), null);
        compare(ev("2 3"), null);
        compare(ev("*3"), null);
    }

    function test_maliciousInputNeverEvaluates() {
        const bad = ["constructor", "alert(1)", "__proto__", "constructor.constructor('return 1')()",
            "this", "process.exit()", "toString", "hasOwnProperty", "Math.PI", "1;2", "a=1", "`1`", "[1]",
            "{}", "'x'", "globalThis", "eval('1')", "sqrt(constructor)", "valueOf()"];
        for (const s of bad)
            compare(ev(s), null, s);
        compare(Calc.answer("constructor"), null);
        compare(Calc.answer("alert(1)"), null);
    }

    function test_deepNestingIsRejectedWithoutCrash() {
        compare(ev("(".repeat(60) + "1" + ")".repeat(60)), null);
        compare(ev("-".repeat(190) + "1"), 1);
        compare(ev("sqrt(".repeat(35) + "1" + ")".repeat(35)), null);
        compare(ev("(".repeat(10) + "1" + ")".repeat(10)), 1);
        compare(ev("1+".repeat(90) + "1"), 91);
        compare(ev("9".repeat(500)), null);
    }

    function test_answerAndFormat() {
        compare(Calc.answer("42"), null);
        compare(Calc.answer("hello"), null);
        compare(Calc.answer("0.1+0.2").text, "0.3");
        compare(Calc.answer("2*(3+4)^2").text, "98");
        compare(Calc.answer("1/3").text, "0.333333333333");
        compare(Calc.answer("pi*1").text, "3.14159265359");
        // A constant's name alone is a word on the way to an app, not a calculation (audit B-16).
        compare(Calc.answer("pi"), null);
        compare(Calc.answer(" e "), null);
        compare(Calc.answer("(pi)").text, "3.14159265359");
    }

    // Capture defect 5: the decimal comma is read and the answer is written the way the language does (grouping included).
    readonly property var fr: Qt.locale("fr_FR")
    readonly property var en: Qt.locale("en_US")

    function test_frenchAnswersAreGroupedWithADecimalComma() {
        const g = fr.groupSeparator;
        compare(Calc.answer("120*163", fr).text, "19" + g + "560");
        compare(Calc.answer("1/3", fr).text, "0,333333333333");
        compare(Calc.answer("pi*1", fr).text, "3,14159265359");
        compare(Calc.answer("1000000*3", fr).text, "3" + g + "000" + g + "000");
        compare(Calc.answer("0,1+0,2", fr).text, "0,3");
        compare(Calc.answer("1,5*2", fr).text, "3");
        compare(Calc.answer("12345,678*10", fr).text, "123" + g + "456,78");
        compare(Calc.answer("-2000*3", fr).text, "-6" + g + "000");
        compare(Calc.answer("1 000 + 5", fr).text, "1" + g + "005");
    }

    function test_englishAnswersAreGroupedWithAPoint() {
        compare(Calc.answer("120*163", en).text, "19,560");
        compare(Calc.answer("1/3", en).text, "0.333333333333");
        compare(Calc.answer("1,000+5", en).text, "1,005");
        compare(Calc.answer("1e20", en), null, "a bare number is not an expression");
        compare(Calc.answer("10^20", en).text, "1e+20");
    }

    function test_smallAndLargeKeepTheirExponent() {
        compare(Calc.answer("10^-12", fr).text, "1e-12");
        compare(Calc.answer("10^16/3", fr).text.indexOf("e") > 0, true);
    }

    function test_withoutALocaleTheAnswerIsPlain() {
        compare(Calc.answer("120*163").text, "19560");
        compare(Calc.format(19560), "19560");
    }
}
