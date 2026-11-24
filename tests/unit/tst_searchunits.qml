import QtQuick
import QtTest
import "../../shell/search/Units.js" as Units

TestCase {
    name: "SearchUnits"

    function test_length() {
        const r = Units.answer("10 km in mi");
        verify(r !== null);
        fuzzyCompare(r.value, 6.2137119, 1e-6);
        compare(r.text, "6.2137 mi");
        compare(Units.answer("1 mile to km").text, "1.6093 km");
        compare(Units.answer("12 in to cm").text, "30.48 cm");
        compare(Units.answer("3 feet in inches").text, "36 in");
    }

    function test_mass() {
        compare(Units.answer("1 kg to lb").text, "2.2046 lb");
        compare(Units.answer("500 g in oz").text, "17.637 oz");
    }

    function test_temperature() {
        compare(Units.answer("100f to c").text, "37.7778 C");
        compare(Units.answer("0 c to f").text, "32 F");
        compare(Units.answer("0 C in K").text, "273.15 K");
        compare(Units.answer("-40 f to c").text, "-40 C");
    }

    function test_dataSizes() {
        compare(Units.answer("2 GiB in MB").text, "2147.4836 MB");
        compare(Units.answer("1 TB to GB").text, "1000 GB");
        compare(Units.answer("1024 mib to gib").text, "1 GiB");
        compare(Units.answer("1 KiB in B").text, "1024 B");
    }

    function test_rejections() {
        compare(Units.answer("10 km in kg"), null);
        compare(Units.answer("10 km in xyz"), null);
        compare(Units.answer("10 km"), null);
        compare(Units.answer("km in mi"), null);
        compare(Units.answer("10 constructor in mi"), null);
        compare(Units.answer("10 km in __proto__"), null);
        compare(Units.answer("10 km in toString"), null);
        compare(Units.answer("x".repeat(500)), null);
        compare(Units.answer("5 usd in eur"), null);
    }

    // Capture defect 5: conversions in the session's language (Spotlight in French).
    readonly property var fr: Qt.locale("fr_FR")
    readonly property var en: Qt.locale("en_US")

    function test_qtLocaleCarriesWhatTheFormatNeeds() {
        compare(fr.decimalPoint, ",");
        verify(fr.groupSeparator !== "" && fr.groupSeparator !== ",");
        compare(en.decimalPoint, ".");
        compare(en.groupSeparator, ",");
    }

    function test_frenchConnectors() {
        compare(Units.answer("25 km en mi", fr).text, "15,5343 mi");
        compare(Units.answer("25 km vers mi", fr).text, "15,5343 mi");
        compare(Units.answer("25 km in mi", fr).text, "15,5343 mi", "the English words keep working in French");
        compare(Units.answer("25 km to mi", fr).text, "15,5343 mi");
        compare(Units.answer("25 km en mi"), null, "en is a French word only");
        compare(Units.answer("25 km en mi", en), null);
        compare(Units.answer("25 km vers mi", en), null);
    }

    function test_decimalComma() {
        fuzzyCompare(Units.answer("2,5 km en m", fr).value, 2500, 1e-9);
        compare(Units.answer("2,5 km en m", fr).text, "2" + fr.groupSeparator + "500 m");
        fuzzyCompare(Units.answer("2.5 km en m", fr).value, 2500, 1e-9);
        fuzzyCompare(Units.answer("0,5 kg en g", fr).value, 500, 1e-9);
        fuzzyCompare(Units.answer("-3,5 c en f", fr).value, 25.7, 1e-9);
        // English: the comma groups thousands, and a lone comma is read as a decimal point.
        fuzzyCompare(Units.answer("1,000 m in km", en).value, 1, 1e-9);
        fuzzyCompare(Units.answer("2,5 km in m", en).value, 2500, 1e-9);
    }

    function test_groupedNumbersAreRead() {
        fuzzyCompare(Units.answer("1 000 m en km", fr).value, 1, 1e-9);
        fuzzyCompare(Units.answer("1" + fr.groupSeparator + "000 m en km", fr).value, 1, 1e-9);
        fuzzyCompare(Units.answer("12 000 000 m en km", fr).value, 12000, 1e-9);
    }

    function test_resultsAreLocalizedAndRounded() {
        const g = fr.groupSeparator;
        compare(Units.answer("25 km in mi", en).text, "15.5343 mi");
        compare(Units.answer("1 TB to B", en).text, "1,000,000,000,000 B");
        compare(Units.answer("1 TB to B", fr).text, "1" + g + "000" + g + "000" + g + "000" + g + "000 B");
        compare(Units.answer("123456 mm en km", fr).text, "0,1235 km");
        compare(Units.answer("2147,483648 mo en go", fr).text, "2,1475 GB");
        compare(Units.answer("1 km en m", fr).text, "1" + g + "000 m");
        compare(Units.answer("0 c en k", fr).text, "273,15 K");
        compare(Units.answer("100 f en c", fr).text, "37,7778 C");
        compare(Units.answer("1 mm en m", fr).text, "0,001 m");
        compare(Units.answer("3 mm en km", fr).text, "0,000003 km");
        // The value stays exact; only the text rounds.
        fuzzyCompare(Units.answer("25 km en mi", fr).value, 15.534279, 1e-6);
    }

    function test_frenchUnitNames() {
        const g = fr.groupSeparator;
        compare(Units.answer("25 kilomètres en miles", fr).to, "mi");
        compare(Units.answer("10 pouces en centimètres", fr).text, "25,4 cm");
        compare(Units.answer("3 pieds en pouces", fr).text, "36 in");
        compare(Units.answer("2 livres en kilogrammes", fr).text, "0,9072 kg");
        compare(Units.answer("500 grammes en onces", fr).text, "17,637 oz");
        compare(Units.answer("2 Go en Mo", fr).text, "2" + g + "000 MB");
        compare(Units.answer("1 Kio en o", fr).text, "1" + g + "024 B");
        compare(Units.answer("10 km en kg", fr), null);
    }

    // Palette slice C2: the new families, number bases, French names.
    function ut(s, loc) {
        const r = Units.answer(s, loc);
        return r ? r.text : null;
    }

    function test_speed() {
        compare(ut("100 km/h in mph"), "62.1371 mph");
        compare(ut("10 m/s to km/h"), "36 km/h");
        compare(ut("60 mph to m/s"), "26.8224 m/s");
        compare(ut("1 knot to km/h"), "1.852 km/h");
        compare(ut("100 km/h en m/s", fr), "27,7778 m/s");
        compare(ut("10 nœuds en km/h", fr), "18,52 km/h");
    }

    function test_area() {
        compare(ut("1 ha to m²"), "10000 m²");
        compare(ut("1 ha to m2"), "10000 m²");
        compare(ut("1 acre to m²"), "4046.8564 m²");
        compare(ut("100 ft² to m²"), "9.2903 m²");
        compare(ut("1 km² en hectares", fr), "100 ha");
        compare(ut("1 m² in ft"), null, "area is not length");
    }

    function test_volume() {
        compare(ut("1 gal to L"), "3.7854 L");
        compare(ut("1 L in mL"), "1000 mL");
        compare(ut("500 ml en cl", fr), "50 cL");
        compare(ut("1 m³ to L"), "1000 L");
        compare(ut("2 cups to ml"), "473.1765 mL");
        compare(ut("1 floz to ml"), "29.5735 mL");
        compare(ut("1 fl oz to ml"), "29.5735 mL");
        compare(ut("2 FL OZ in cups"), "0.25 cup");
        compare(ut("1 cup to fl oz"), "8 fl oz");
        compare(ut("1 fluid ounce to ml"), "29.5735 mL");
        compare(ut("2 litres en gallons", fr), "0,5283 gal");
    }

    function test_time() {
        compare(ut("90 min to h"), "1.5 h");
        compare(ut("2 days in hours"), "48 h");
        compare(ut("1 week to d"), "7 d");
        compare(ut("3 heures en minutes", fr), "180 min");
        compare(ut("1 jour en secondes", fr), "86" + fr.groupSeparator + "400 s");
        compare(ut("1500 ms to s"), "1.5 s");
        compare(ut("1 h in kg"), null);
    }

    function test_pressure() {
        compare(ut("1 atm to kPa"), "101.325 kPa");
        compare(ut("1 bar to psi"), "14.5038 psi");
        compare(ut("760 mmhg to atm"), "1 atm");
        compare(ut("1 bar en pascals", fr), "100" + fr.groupSeparator + "000 Pa");
    }

    function test_energy() {
        compare(ut("1 kWh to kJ"), "3600 kJ");
        compare(ut("1 kcal to kJ"), "4.184 kJ");
        compare(ut("100 kcal en joules", fr), "418" + fr.groupSeparator + "400 J");
        compare(ut("1 kWh to Wh"), "1000 Wh");
    }

    function test_angles() {
        compare(ut("180 deg to rad"), "3.1416 rad");
        compare(ut("180° to rad"), "3.1416 rad");
        compare(ut("1 turn to deg"), "360 °");
        compare(ut("90 degrés en radians", fr), "1,5708 rad");
        compare(ut("100 grad to deg"), "90 °");
    }

    function test_numberBases() {
        compare(ut("255 to hex"), "0xff");
        compare(ut("255 in bin"), "0b11111111");
        compare(ut("0xff in dec"), "255");
        compare(ut("0xFF to decimal"), "255");
        compare(ut("ff hex to dec"), "255");
        compare(ut("1010 bin to dec"), "10");
        compare(ut("0b1010 to hex"), "0xa");
        compare(ut("8 to oct"), "0o10");
        compare(ut("0o17 to dec"), "15");
        compare(ut("-255 to hex"), "-0xff");
        compare(ut("255 en hexadécimal", fr), "0xff");
        compare(ut("0xff vers décimal", fr), "255");
        compare(ut("1 000 en hex", fr), "0x3e8");
        compare(ut("65535 to hex"), "0xffff");
        compare(Units.answer("255 to hex").value, 255);
        compare(Units.answer("255 to hex").to, "hex");
        compare(ut("0xff en hex"), null, "en is a French word only");
        compare(ut("ff to dec"), null, "digits without a base are decimal");
        compare(ut("12 bin to dec"), null);
        // "0b12 hex" is ambiguous: 0b is the binary prefix, but 12 is no binary number (it could also be the hex digits
        // 0, b, 1, 2). It stays refused rather than guessed.
        compare(ut("0b12 hex to dec"), null);
        compare(ut("0b12 to dec"), null);
        compare(ut("0xff bin to dec"), null, "the prefix and the named base must agree");
        compare(ut("1.5 to hex"), null);
        compare(ut("9007199254740993 to hex"), null, "beyond 2^53 - 1 is refused");
        compare(ut("0x to dec"), null);
    }

    function test_noCurrencyEvenWithNewNames() {
        compare(ut("5 usd in eur"), null);
        compare(ut("5 eur en cad", fr), null);
    }

    function test_noGroupingWithoutALocale() {
        compare(Units.answer("1 km in m").text, "1000 m");
    }
}
