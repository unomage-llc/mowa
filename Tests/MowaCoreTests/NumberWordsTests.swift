import XCTest
@testable import MowaCore

final class NumberWordsTests: XCTestCase {
    func ru(_ s: String) -> String { NumberWords.digits(s, language: .russian) }
    func en(_ s: String) -> String { NumberWords.digits(s, language: .english) }

    func testRussianEvalCases() {
        XCTAssertEqual(ru("Счет на тысячу двести пятьдесят рублей оплатить до пятнадцатого."),
                       "Счет на 1250 рублей оплатить до 15-го.")
        XCTAssertEqual(ru("Мой номер плюс семь девятьсот шестнадцать, сто двадцать три, сорок пять, шестьдесят семь."),
                       "Мой номер +7 916 123 45 67.")
        XCTAssertEqual(ru("Нужно три с половиной килограмма муки и двести миллилитров молока."),
                       "Нужно три с половиной килограмма муки и 200 миллилитров молока.")
        XCTAssertEqual(ru("В прошлом году у нас было два миллиона триста тысяч пользователей."),
                       "В прошлом году у нас было 2 300 000 пользователей.")
        XCTAssertEqual(ru("Созвон завтра в девять тридцать утра."), "Созвон завтра в 9:30 утра.")
    }

    func testRussianWordsThatStay() {
        XCTAssertEqual(ru("Встречаемся в пять у метро."), "Встречаемся в пять у метро.")
        XCTAssertEqual(ru("Я люблю свою семью."), "Я люблю свою семью.")
        XCTAssertEqual(ru("Тысячу раз говорил."), "Тысячу раз говорил.")
        XCTAssertEqual(ru("Сто лет не виделись."), "Сто лет не виделись.")
        XCTAssertEqual(ru("На пятом этаже два кабинета."), "На пятом этаже два кабинета.")
        XCTAssertEqual(ru("Дойди до пятого подъезда."), "Дойди до пятого подъезда.")
        XCTAssertEqual(ru("Один из них опоздал."), "Один из них опоздал.")
    }

    func testRussianOtherNumbers() {
        XCTAssertEqual(ru("Мне двадцать пять лет."), "Мне 25 лет.")
        XCTAssertEqual(ru("Купи сорок две штуки."), "Купи 42 штуки.")
        XCTAssertEqual(ru("Цена двенадцать тысяч пятьсот рублей."), "Цена 12 500 рублей.")
    }

    func testEnglishEvalCases() {
        XCTAssertEqual(en("My number is five five five, two three four, six seven eight nine."), "My number is 555 234 6789.")
        XCTAssertEqual(en("My number is five five five two three four six seven eight nine."), "My number is 5552346789.")
        XCTAssertEqual(en("The total is twelve hundred and fifty dollars."), "The total is 1,250 dollars.")
        XCTAssertEqual(en("Let's meet at four, no wait, at five thirty."), "Let's meet at four, no wait, at 5:30.")
        XCTAssertEqual(en("The train leaves at nine thirty in the morning."), "The train leaves at 9:30 in the morning.")
        XCTAssertEqual(en("The package weighs three point five kilograms."), "The package weighs 3.5 kilograms.")
        XCTAssertEqual(en("The city has about two point three million people."), "The city has about 2.3 million people.")
        XCTAssertEqual(en("The conference is on March fourteenth, twenty twenty seven."), "The conference is on March fourteenth, 2027.")
    }

    func testEnglishWordsThatStay() {
        XCTAssertEqual(en("What's two plus two?"), "What's two plus two?")
        XCTAssertEqual(en("One of them is late."), "One of them is late.")
        XCTAssertEqual(en("I told you a thousand times."), "I told you a thousand times.")
        XCTAssertEqual(en("This is the twenty first time."), "This is the twenty first time.")
        XCTAssertEqual(en("I have one, two and three."), "I have one, two and three.")
    }

    func testEnglishOtherNumbers() {
        XCTAssertEqual(en("We need twenty five chairs."), "We need 25 chairs.")
        XCTAssertEqual(en("About three hundred forty people came."), "About 340 people came.")
        XCTAssertEqual(en("It costs two thousand and five dollars."), "It costs 2,005 dollars.")
    }

    func testOtherLanguagesUntouched() {
        XCTAssertEqual(NumberWords.digits("Mam dwadzieścia pięć lat.", language: .polish), "Mam dwadzieścia pięć lat.")
    }

    func testRussianDates() {
        XCTAssertEqual(ru("Конференция пройдёт третьего марта две тысячи двадцать седьмого года."),
                       "Конференция пройдёт 3 марта 2027 года.")
        XCTAssertEqual(ru("Встреча двадцать первого сентября."), "Встреча 21 сентября.")
        XCTAssertEqual(ru("Это было в тысяча девятьсот девяносто восьмом году."), "Это было в 1998 году.")
        XCTAssertEqual(ru("Сделай к двадцать пятому, пожалуйста."), "Сделай к 25-му, пожалуйста.")
        XCTAssertEqual(ru("Отпуск с десятого по двадцатое."), "Отпуск с 10-го по 20-е.")
    }
}
