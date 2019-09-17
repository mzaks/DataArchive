import XCTest
import DataArchive

final class DataArchiveTests: XCTestCase {
    let archive = DataArchive.default

    func testSetPerson() {
        let exp = expectation(description: "wait for set")
        let person = Person(name: "Maxim", age: 38)
        let value = JSONValueConverter(value: person)
        var result: DataArchiveResult?
        archive.set(key: "person1", value: value) { (_result) in
            result = _result
            exp.fulfill()
        }
        waitForExpectations(timeout: 1, handler: nil)
        print(result as Any)
        XCTAssert(result?.isSuccess ?? false)
        self.delete(key: "person1")
    }

    func testGetPersonAfterDelete() {
        var result: DataArchiveResult?
        var person: Person?

        delete(key: "person2")

        let exp = expectation(description: "wait for get")
        self.archive.get(key: "person2", converterType: JSONValueConverter<Person>.self) { (_person, _result) in
            result = _result
            person = _person
            exp.fulfill()
        }

        waitForExpectations(timeout: 1, handler: nil)
        XCTAssert(result?.isSuccess == false)
        XCTAssertNil(person)
    }

    func testSetAndGetPerson() {
        let key = "person3"
        let exp1 = expectation(description: "1")
        let exp2 = expectation(description: "2")
        var result: DataArchiveResult?
        var person: Person?

        let value = JSONValueConverter(value: Person(name: "Maxim", age: 38))

        archive.set(key: key, value: value) { (_result) in
            exp1.fulfill()
        }

        archive.get(key: key, converterType: JSONValueConverter<Person>.self) { (_person, _result) in
            result = _result
            person = _person
            exp2.fulfill()
        }

        waitForExpectations(timeout: 1, handler: nil)
        XCTAssert(result?.isSuccess == true)
        XCTAssertEqual(person?.name, "Maxim")
        XCTAssertEqual(person?.age, 38)

        delete(key: key)
    }

    func testSetMultipleVersionsOfPersonsAsync() {
        let key = "persons"
        let exp1 = expectation(description: "1")
        let exp2 = expectation(description: "2")
        let exp3 = expectation(description: "3")
        archive.archiveCurrent(key: key, andSetNew: JSONValueConverter(value: Person(name: "Maxim", age: 1))) { _ in
            exp1.fulfill()
        }
        archive.archiveCurrent(key: key, andSetNew: JSONValueConverter(value: Person(name: "Maxim", age: 2))) { _ in
            exp2.fulfill()
        }
        archive.archiveCurrent(key: key, andSetNew: JSONValueConverter(value: Person(name: "Maxim", age: 3))) { _ in
            exp3.fulfill()
        }
        waitForExpectations(timeout: 2, handler: nil)
        print("Done Waiting")

        let exp4 = expectation(description: "4")
        var persons = [Person]()
        var result: DataArchiveResult?
        archive.getAll(key: key, converterType: JSONValueConverter<Person>.self) { (_persons, _result) in
            print("Got All")
            persons = _persons
            result = _result
            exp4.fulfill()
        }

        waitForExpectations(timeout: 1, handler: nil)
        XCTAssertEqual(persons.count, 3)
        XCTAssertEqual(persons[0].age, 3)
        XCTAssertEqual(persons[1].age, 2)
        XCTAssertEqual(persons[2].age, 1)
        XCTAssert(result?.isSuccess == true)
        delete(key: key)
    }

    func testLazyLockingReader() {
        let key = "persons2"
        for i in 1...5 {
            archive.archiveCurrent(key: key, andSetNew: JSONValueConverter(value: Person(name: "Maxim", age: i)))
        }
        var ageToAssert = 5
        func read(with reader: DataArchiveLazyLockingReader) {
            reader.getNext(converterType: JSONValueConverter<Person>.self) { (person, result) in
                if result.isSuccess {
                    XCTAssertEqual(person?.age, ageToAssert)
                    ageToAssert -= 1
                    read(with: reader)
                }
            }
        }

        archive.lazyLockingReader(key: key) { (reader) in
            read(with: reader!)
        }

        archive.archiveCurrent(key: key, andSetNew: JSONValueConverter(value: Person(name: "Max", age: 11)))

        archive.getAll(key: key) { (people, result) in
            XCTAssert(result.isSuccess)
            XCTAssertEqual(people.count, 6)
        }

        delete(key: key)

        XCTAssertEqual(ageToAssert, 0)
    }

    func testKeepUpTo() {
        let key = "person5"
        for i in 1...10 {
            archive.archiveCurrent(key: key, andSetNew: JSONValueConverter(value: Person(name: "Maxim", age: i)))
        }
        archive.get(key: key, converterType: JSONValueConverter<Person>.self) { (person, result) in
            XCTAssert(result.isSuccess)
            XCTAssertEqual(person?.age, 10)
        }

        archive.keep(upTo: 5, archivesForKey: key)
        archive.getAll(key: key, converterType: JSONValueConverter<Person>.self) { (people, result) in
            XCTAssert(result.isSuccess)
            XCTAssertEqual(people.count, 6)
            XCTAssertEqual(people[0].age, 10)
            XCTAssertEqual(people[1].age, 9)
            XCTAssertEqual(people[2].age, 8)
            XCTAssertEqual(people[3].age, 7)
            XCTAssertEqual(people[4].age, 6)
            XCTAssertEqual(people[5].age, 5)
        }

        delete(key: key)
    }

    func testSetGetData() {
        let key = "data1"
        let data = Data([1, 2, 3, 4, 5])
        archive.set(key: key, data: data)
        archive.get(key: key) { (d, result) in
            XCTAssert(result.isSuccess)
            XCTAssertEqual(d, data)
        }
        delete(key: key)
    }

    func testMultipleData() {
        let key = "data2"
        for i in 1 ... 10 {
            archive.archiveCurrent(
                key: key,
                andSetNewData: Data([1, 2, 3, UInt8(i)])
            )
        }

        archive.lazyLockingReader(key: key) { (reader) in
            reader?.getNext(completionHandler: { (data, result) in
                XCTAssert(result.isSuccess)
                XCTAssertEqual(data, Data([1, 2, 3, 10]))
                reader?.finish()
            })
        }

        archive.keep(upTo: 2, archivesForKey: key)

        archive.getAll(key: key) { (dataArray, result) in
            XCTAssert(true)
            XCTAssertEqual(dataArray.count, 3)
            XCTAssertEqual(dataArray[0], Data([1, 2, 3, 10]))
            XCTAssertEqual(dataArray[1], Data([1, 2, 3, 9]))
            XCTAssertEqual(dataArray[2], Data([1, 2, 3, 8]))
        }

        delete(key: key)
    }

    func testMultipleKeys() {
        for i in 1...10 {
            archive.set(key: "key\(i)", data: Data([1, 2, 3, UInt8(i)]))
        }

        //        var numberOfAssertedValues = 0
        for i in 1...10 {
            archive.get(key: "key\(i)") { (data, result) in
                XCTAssert(result.isSuccess)
                XCTAssertEqual(data, Data([1, 2, 3, UInt8(i)]))
                //                numberOfAssertedValues += 1
                print("Asserted \(i)")
            }
        }

        delete(key: "key1")
        delete(key: "key2")
        delete(key: "key3")
        delete(key: "key4")
        delete(key: "key5")
        delete(key: "key6")
        delete(key: "key7")
        delete(key: "key8")
        delete(key: "key9")
        delete(key: "key10")

        XCTAssertEqual(archive.keys.count, 0)
        //        XCTAssertEqual(numberOfAssertedValues, 10)
    }

    private func delete(key: String) {
        let exp = expectation(description: "wait for delete")
        archive.delete(key: key) { _ in
            exp.fulfill()
        }
        waitForExpectations(timeout: 20, handler: nil)
        XCTAssert(archive.keys.contains(key) == false)
    }

    static var allTests = [
        ("testSetPerson", testSetPerson),
        ("testGetPersonAfterDelete", testGetPersonAfterDelete),
        ("testSetAndGetPerson", testSetAndGetPerson),
        ("testSetMultipleVersionsOfPersonsAsync", testSetMultipleVersionsOfPersonsAsync),
        ("testLazyLockingReader", testLazyLockingReader),
        ("testKeepUpTo", testKeepUpTo),
        ("testSetGetData", testSetGetData),
        ("testMultipleData", testMultipleData),
        ("testMultipleKeys", testMultipleKeys),
    ]
}

class Person: Codable {
    let name: String
    let age: Int
    init(name: String, age: Int) {
        self.name = name
        self.age = age
    }
}
