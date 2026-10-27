import Foundation

/// First names typed in lowercase ("передай андрею", "napisz do kasi") get their capital letter.
/// Speech recognition and the cleanup model both drop it now and then, and restoreNames can only
/// put back what the transcript had (Drew 2026-10-24: «андрей»). Common first names in Mowa's
/// languages, with their case forms for Russian and Polish; names that are also everyday words
/// (Вера, Роман, Света, Коля, Grace, Mark, Will, Claire, Chiara, Pierre, Ola…) are left out.
/// Never inside an e-mail address, URL, @handle or file name.
public enum KnownNames {
    static let russianMale = ["Александр", "Алексей", "Андрей", "Антон", "Аркадий", "Арсений", "Артём", "Артур", "Борис", "Вадим",
        "Валентин", "Валерий", "Василий", "Виктор", "Виталий", "Владимир", "Владислав", "Всеволод", "Вячеслав", "Геннадий",
        "Георгий", "Глеб", "Григорий", "Даниил", "Денис", "Дмитрий", "Евгений", "Егор", "Иван", "Игорь", "Илья", "Кирилл",
        "Константин", "Леонид", "Максим", "Марат", "Матвей", "Михаил", "Николай", "Олег", "Павел", "Пётр", "Руслан", "Семён",
        "Сергей", "Станислав", "Стас", "Степан", "Тимофей", "Тимур", "Фёдор", "Филипп", "Эдуард", "Юрий", "Ярослав"]
    /// Names ending in -а/-я, men's short forms included (they decline the same way).
    static let russianA = ["Анна", "Анастасия", "Алёна", "Алина", "Алла", "Валентина", "Валерия", "Варвара", "Вероника",
        "Виктория", "Галина", "Дарья", "Диана", "Евгения", "Екатерина", "Елена", "Елизавета", "Жанна", "Зоя", "Инна", "Ирина",
        "Карина", "Кира", "Кристина", "Ксения", "Лариса", "Лидия", "Людмила", "Маргарита", "Марина", "Мария", "Милана",
        "Наталья", "Наталия", "Нина", "Оксана", "Олеся", "Ольга", "Полина", "Светлана", "Софья", "София", "Тамара", "Татьяна",
        "Ульяна", "Юлия", "Яна", "Аня", "Катя", "Маша", "Даша", "Наташа", "Оля", "Таня", "Лена", "Ира", "Настя", "Юля", "Лиза",
        "Соня", "Ксюша", "Вика", "Женя", "Галя", "Саша", "Дима", "Миша", "Серёжа", "Петя", "Ваня", "Вова", "Володя", "Лёша",
        "Алёша", "Паша", "Гриша", "Костя", "Витя", "Толя", "Юра", "Никита", "Илья"]
    static let polishMale = ["Adam", "Adrian", "Aleksander", "Andrzej", "Antoni", "Artur", "Bartosz", "Bogdan", "Damian", "Daniel",
        "Dariusz", "Dawid", "Dominik", "Filip", "Grzegorz", "Hubert", "Igor", "Jakub", "Janusz", "Jarosław", "Kamil", "Karol",
        "Krzysztof", "Łukasz", "Maciej", "Marcin", "Mariusz", "Mateusz", "Michał", "Mikołaj", "Patryk", "Piotr", "Przemysław",
        "Rafał", "Robert", "Ryszard", "Sebastian", "Szymon", "Tadeusz", "Tomasz", "Wiktor", "Wojciech", "Zbigniew"]
    /// -ek names lose their e ("Marek" → "Marka"), -eł names too ("Paweł" → "Pawła").
    static let polishEk = ["Marek", "Tomek", "Bartek", "Wojtek", "Jacek", "Paweł", "Franek", "Józek"]
    static let polishA = ["Agnieszka", "Aleksandra", "Alicja", "Aneta", "Anna", "Ania", "Asia", "Barbara", "Basia", "Beata", "Dorota",
        "Edyta", "Elżbieta", "Emilia", "Ewa", "Ewelina", "Gosia", "Halina", "Hanna", "Irena", "Iwona", "Joanna", "Jolanta", "Julia",
        "Justyna", "Kamila", "Karolina", "Kasia", "Katarzyna", "Kinga", "Krystyna", "Kuba", "Magda", "Magdalena", "Małgorzata",
        "Maria", "Marta", "Monika", "Natalia", "Oliwia", "Paulina", "Urszula", "Weronika", "Wiktoria", "Zofia", "Zosia"]
    /// Other languages: no case endings to generate.
    static let plain = ["Alex", "Alice", "Andrew", "Anthony", "Benjamin", "Charles", "Charlotte", "Chris", "Christopher", "David",
        "Emily", "Emma", "George", "Hannah", "Henry", "Jacob", "James", "Jennifer", "Jessica", "John", "Joseph", "Joshua", "Kevin",
        "Laura", "Linda", "Lisa", "Matthew", "Michael", "Nancy", "Nicholas", "Olivia", "Patrick", "Paul", "Peter", "Rachel",
        "Richard", "Ryan", "Sarah", "Sophia", "Steven", "Susan", "Thomas", "William", "Andreas", "Stefan", "Jürgen", "Klaus",
        "Wolfgang", "Lukas", "Felix", "Lena", "Sabine", "Katrin", "Ursula", "Jean", "Sophie", "Camille", "Julien", "Nicolas",
        "Antoine", "Mathieu", "Léa", "Chloé", "Manon", "Juan", "José", "Carlos", "Javier", "Miguel", "Pablo", "Lucía", "María",
        "Carmen", "Sofía", "Elena", "Marco", "Giuseppe", "Giovanni", "Luca", "Matteo", "Alessandro", "Francesca", "Giulia",
        "Sara", "João", "Pedro", "Lucas", "Gabriel", "Rafael", "Ana", "Beatriz", "Mariana", "Camila", "Gustavo"]

    static func russianForms(_ n: String) -> [String] {
        let s = String(n.dropLast()), last = n.last!
        let hard = "гкхжшчщ"
        switch last {
        case "й": return [n, s + "я", s + "ю", s + "ем", s + "е", s + "и"]
        case "ь": return [n, s + "я", s + "ю", s + "ем", s + "е"]
        case "а": return [n, s + (hard.contains(s.last ?? " ") ? "и" : "ы"), s + "е", s + "у", s + "ой", s + "ою"]
        case "я": return [n, s + "и", s + "е", s + "ю", s + "ей"]
        default:
            if n == "Павел" { return ["Павел", "Павла", "Павлу", "Павлом", "Павле"] }
            if n == "Пётр" { return ["Пётр", "Петра", "Петру", "Петром", "Петре", "Петр"] }
            return [n, n + "а", n + "у", n + "ом", n + "е"]
        }
    }

    static func polishForms(_ n: String) -> [String] {
        if n.hasSuffix("a") {
            let s = String(n.dropLast())
            let soft = s.hasSuffix("i") || s.hasSuffix("k") || s.hasSuffix("g") || s.hasSuffix("l")
            let gen = s.hasSuffix("i") ? s : s + (soft ? "i" : "y")
            return [n, gen, s + "ę", s + "ą"]   // no vocative: "Anno", "Julio" are Italian/Spanish words
        }
        if polishEk.contains(n) {
            let s = n.hasSuffix("ł") ? String(n.dropLast(2)) + "ł" : String(n.dropLast(2)) + String(n.last!)
            return [n, s + "a", s + "owi", s + "iem", s + "em", s + "u"]
        }
        let k = n.hasSuffix("k") || n.hasSuffix("g")
        return [n, n + "a", n + "owi", n + (k ? "iem" : "em"), n + "ie", n + "u"]
    }

    static let all: [String: String] = {
        var forms: [String] = plain
        for n in russianMale + russianA { forms += russianForms(n) }
        for n in polishMale + polishEk + polishA { forms += polishForms(n) }
        // «Артём» is often typed «Артем».
        forms += forms.filter { $0.contains("ё") }.map { $0.replacingOccurrences(of: "ё", with: "е") }
        // Case forms that are everyday words: Polish "marka" (a brand).
        let words: Set<String> = ["marka"]
        var out: [String: String] = [:]
        for f in forms where f.count >= 3 && !words.contains(f.lowercased()) { out[f.lowercased()] = f }
        return out
    }()

    public static func capitalize(_ text: String) -> String {
        guard text.contains(where: { $0.isLowercase }),
              let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}@._/\\\\#-])\\p{Ll}[\\p{L}]+(?![\\p{L}\\p{N}@_/\\\\-]|\\.[\\p{L}\\p{N}])")
        else { return text }
        let ns = text as NSString
        var out = text
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let word = ns.substring(with: m.range)
            guard let name = all[word], let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: name)
        }
        return out
    }
}
