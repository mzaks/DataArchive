//
//  DataArchive.swift
//  DataArchive
//
//  Created by Maxim Zaks on 12.09.19.
//  Copyright © 2019 maxim.zaks. All rights reserved.
//

import Foundation

public protocol ValueConverter {
    associatedtype T
    static func from(data: Data) -> Self?
    var toData: Data? { get }
    var value: T { get }
}

public enum DataArchiveResult {
    case success
    case fileNotFound(URL)
    case couldNotConvertFile(URL, String)
    case couldNotMoveFile(URL, URL, Error)
    case coludNotDeleteFile(URL, Error)
    case couldNotWriteToFile(URL, Error)
    case limitNeedsToBePositiveNumber
    case lockingReaderWasFinished
    case couldNotDeleteKey(URL, Error)
    case couldNotArchiveButCouldSet

    public var isSuccess: Bool {
        switch self {
        case .success:
            return true
        default:
            return false
        }
    }
}

public typealias DataArchiveCompletionHandler = (DataArchiveResult) -> Void

private let sharedArchive = DataArchive()

public final class DataArchive {
    let baseUrl: URL
    private var semaphorTable = [String: DispatchSemaphore]()
    private var queueTable = [String: DispatchQueue]()

    public static var `default`: DataArchive { return sharedArchive }

    public init(rootUrl: URL? = nil) {
        let root: URL
        if rootUrl == nil {
            let libPath = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true).first!
            root = URL(fileURLWithPath: libPath)
        } else {
            root = rootUrl!
        }

        baseUrl = root.appendingPathComponent("data_archive", isDirectory: true)
    }

    public func set<T: ValueConverter>(key: String, value: T, completionHandler: DataArchiveCompletionHandler? = nil) {
        lock(key: key) { folderUrl in
            let fileUrl = folderUrl.appendingPathComponent("0.dat")
            let tempFile = folderUrl.appendingPathComponent("0.tmp")
            var movedToTemp = false
            do {
                try FileManager.default.moveItem(at: fileUrl, to: tempFile)
                movedToTemp = true
            } catch {
                // TODO: decide if it is ok to go further
            }
            do {
                try value.toData?.write(to: fileUrl)
                completionHandler?(.success)
                if movedToTemp == true {
                    try?FileManager.default.removeItem(at: tempFile)
                }
            } catch let error {
                completionHandler?(.couldNotWriteToFile(fileUrl, error))
            }
        }
    }

    public func set(key: String, data: Data, completionHandler: DataArchiveCompletionHandler? = nil) {
        set(key: key, value: DataValueConverter(value: data), completionHandler: completionHandler)
    }

    public func archiveCurrent<T: ValueConverter>(key: String, andSetNew value: T, completionHandler: DataArchiveCompletionHandler? = nil) {

        lock(key: key) { (folderUrl) in
            let fileUrl = folderUrl.appendingPathComponent("0.dat")
            let archiveIndex = self.numberOfArchives(key: key) + 1
            let archiveUrl = folderUrl.appendingPathComponent("\(archiveIndex).dat")
            var couldArchive = true
            do {
                try FileManager.default.moveItem(at: fileUrl, to: archiveUrl)
            } catch {
                couldArchive = false
            }
            do {
                try value.toData?.write(to: fileUrl)
                if couldArchive {
                    completionHandler?(.success)
                } else {
                    completionHandler?(.couldNotArchiveButCouldSet)
                }
            } catch let error {
                completionHandler?(.couldNotWriteToFile(fileUrl, error))
            }
        }
    }

    public func archiveCurrent(key: String, andSetNewData data: Data, completionHandler: DataArchiveCompletionHandler? = nil) {
        archiveCurrent(key: key, andSetNew: DataValueConverter(value: data), completionHandler: completionHandler)
    }

    public func keep(upTo limit: Int, archivesForKey key: String, completionHandler: DataArchiveCompletionHandler? = nil) {
        guard limit > 0 else {
            completionHandler?(.limitNeedsToBePositiveNumber)
            return
        }
        lock(key: key) { [unowned self] (folderUrl) in
            let archiveCount = self.numberOfArchives(key: key)
            guard archiveCount > limit else {
                completionHandler?(.success)
                return
            }
            let acrchivesToDelete = archiveCount - limit
            // rename files to delete
            for index in 1...acrchivesToDelete {
                let fileUrl = folderUrl.appendingPathComponent("\(index).dat")
                let tempUrl = folderUrl.appendingPathComponent("\(index).tmp")
                do {
                    try FileManager.default.moveItem(at: fileUrl, to: tempUrl)
                } catch let error {
                    completionHandler?(.couldNotMoveFile(fileUrl, tempUrl, error))
                    return
                }
            }
            // move archives to stay
            for index in (acrchivesToDelete+1)...archiveCount {
                let fileUrl = folderUrl.appendingPathComponent("\(index).dat")
                let tempUrl = folderUrl.appendingPathComponent("\(index - acrchivesToDelete).dat")
                do {
                    try FileManager.default.moveItem(at: fileUrl, to: tempUrl)
                } catch {
                    completionHandler?(.couldNotMoveFile(fileUrl, tempUrl, error))
                    return
                }
            }
            // delete archives to delete
            for index in 1...acrchivesToDelete {
                let tempUrl = folderUrl.appendingPathComponent("\(index).tmp")
                do {
                    try FileManager.default.removeItem(at: tempUrl)
                } catch let error {
                    completionHandler?(.coludNotDeleteFile(tempUrl, error))
                    return
                }
            }
            completionHandler?(.success)
        }
    }

    public func get<T: ValueConverter>(key: String, converterType: T.Type, completionHandler: @escaping (T.T?, DataArchiveResult) -> Void) {

        lock(key: key) { folderUrl in
            let fileUrl = folderUrl.appendingPathComponent("0.dat")
            func tryReadFromTemp() {
                let tempFile = folderUrl.appendingPathComponent("0.tmp")
                do {
                    let data = try Data(contentsOf: tempFile)
                    if let fileContent = T.from(data: data)?.value {
                        completionHandler(fileContent, .success)
                    } else {
                        completionHandler(nil, .couldNotConvertFile(tempFile, "\(T.self)"))
                    }
                } catch {
                    completionHandler(nil, .couldNotConvertFile(fileUrl, "\(T.self)"))
                }
            }
            do {
                let data = try Data(contentsOf: fileUrl)

                if let fileContent = T.from(data: data)?.value {
                    completionHandler(fileContent, .success)
                } else {
                    tryReadFromTemp()
                }
            } catch {
                tryReadFromTemp()
            }
        }
    }

    public func getAll<T: ValueConverter>(key: String, converterType: T.Type, completionHandler: @escaping ([T.T], DataArchiveResult) -> Void) {
        lock(key: key) { [unowned self] folderUrl in
            func tryReadFromFile(fileIndex: Int) -> Data? {
                let file = folderUrl.appendingPathComponent("\(fileIndex).dat")
                return try? Data(contentsOf: file)
            }
            func tryReadFromTemp(fileIndex: Int) -> Data? {
                let file = folderUrl.appendingPathComponent("\(fileIndex).tmp")
                return try? Data(contentsOf: file)
            }
            var fileIndex = 0
            var result = [T.T]()
            if let data = tryReadFromFile(fileIndex: fileIndex),
                let value = T.from(data: data)?.value {
                result.append(value)
            } else if let data = tryReadFromTemp(fileIndex: fileIndex),
                let value = T.from(data: data)?.value {
                result.append(value)
            } else {
                let file = folderUrl.appendingPathComponent("\(fileIndex).dat")
                completionHandler(result, .couldNotConvertFile(file, "\(T.self)"))
                return
            }
            let numberOfArchives = self.numberOfArchives(key: key)
            guard numberOfArchives > 0 else {
                completionHandler(result, .success)
                return
            }
            for i in (1...numberOfArchives).reversed() {
                fileIndex = i
                if let data = tryReadFromFile(fileIndex: fileIndex),
                    let value = T.from(data: data)?.value {
                    result.append(value)
                } else if let data = tryReadFromTemp(fileIndex: fileIndex),
                    let value = T.from(data: data)?.value {
                    result.append(value)
                } else {
                    let file = folderUrl.appendingPathComponent("\(fileIndex).dat")
                    completionHandler(result, .couldNotConvertFile(file, "\(T.self)"))
                    return
                }
            }
            completionHandler(result, .success)
        }
    }

    public func get(key: String, completionHandler: @escaping (Data?, DataArchiveResult) -> Void) {

        lock(key: key) { folderUrl in
            let fileUrl = folderUrl.appendingPathComponent("0.dat")
            func tryReadFromTemp() {
                let tempFile = folderUrl.appendingPathComponent("0.tmp")
                do {
                    let data = try Data(contentsOf: tempFile)
                    completionHandler(data, .success)
                } catch {
                    completionHandler(nil, .success)
                }
            }
            do {
                let data = try Data(contentsOf: fileUrl)
                completionHandler(data, .success)
            } catch {
                tryReadFromTemp()
            }
        }
    }

    public func getAll(key: String, completionHandler: @escaping ([Data], DataArchiveResult) -> Void) {
        lock(key: key) { [unowned self] folderUrl in
            func tryReadFromFile(fileIndex: Int) -> Data? {
                let file = folderUrl.appendingPathComponent("\(fileIndex).dat")
                return try? Data(contentsOf: file)
            }
            func tryReadFromTemp(fileIndex: Int) -> Data? {
                let file = folderUrl.appendingPathComponent("\(fileIndex).tmp")
                return try? Data(contentsOf: file)
            }
            var fileIndex = 0
            var result = [Data]()
            if let data = tryReadFromFile(fileIndex: fileIndex) {
                result.append(data)
            } else if let data = tryReadFromTemp(fileIndex: fileIndex) {
                result.append(data)
            } else {
                let file = folderUrl.appendingPathComponent("\(fileIndex).dat")
                completionHandler(result, .fileNotFound(file))
                return
            }
            let numberOfArchives = self.numberOfArchives(key: key)
            guard numberOfArchives > 0 else {
                completionHandler(result, .success)
                return
            }
            for i in (1...numberOfArchives).reversed() {
                fileIndex = i
                if let data = tryReadFromFile(fileIndex: fileIndex) {
                    result.append(data)
                } else if let data = tryReadFromTemp(fileIndex: fileIndex) {
                    result.append(data)
                } else {
                    let file = folderUrl.appendingPathComponent("\(fileIndex).dat")
                    completionHandler(result, .fileNotFound(file))
                    return
                }
            }
            completionHandler(result, .success)
        }
    }

    public func lazyLockingReader(key: String, completionHandler: @escaping (DataArchiveLazyLockingReader?) -> Void) {
        var semaphor: DispatchSemaphore?
        var queue: DispatchQueue?
        let folderUrl = self.baseUrl.appendingPathComponent(key, isDirectory: true)
        DispatchQueue.main.async { [unowned self] in
            semaphor = self.semaphorTable[key]
            queue = self.queueTable[key]
            if semaphor == nil {
                // Create semaphor if the folder exista and is not empty
                let numberOfFiles = (try?FileManager.default.contentsOfDirectory(at: folderUrl, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles, .skipsPackageDescendants]))?.count ?? 0
                if numberOfFiles > 0 {
                    semaphor = DispatchSemaphore(value: 1)
                    queue = DispatchQueue(label: key)
                    self.semaphorTable[key] = semaphor!
                    self.queueTable[key] = queue
                }
            }
            guard let _semaphor = semaphor else {
                completionHandler(nil)
                return
            }
            queue?.async {
                _semaphor.wait()
                completionHandler(
                    DataArchiveLazyLockingReader(
                        semaphor: _semaphor,
                        folderUrl: folderUrl,
                        numberOfArchives: self.numberOfArchives(key: key)
                    )
                )
            }
        }
    }

    public var keys: [String] {
        do {
            return try FileManager.default.contentsOfDirectory(at: baseUrl, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles, .skipsPackageDescendants]).compactMap {
                if $0.hasDirectoryPath {
                    return $0.lastPathComponent
                } else {
                    return nil
                }
            }
        } catch {
            return []
        }
    }

    public func numberOfArchives(key: String) -> Int {
        do {
            let keyUrl = baseUrl.appendingPathComponent(key)
            return try FileManager.default.contentsOfDirectory(
                at: keyUrl,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles, .skipsPackageDescendants]
                ).filter{
                    $0.pathExtension == "dat" && $0.lastPathComponent.starts(with: "0") == false
                }.count
        } catch {
            return 0
        }
    }

    public func delete(key: String, completionHandler: DataArchiveCompletionHandler? = nil) {
        lock(key: key) { (folderUrl) in
            do {
                try FileManager.default.removeItem(at: folderUrl)
                completionHandler?(.success)
            } catch let error {
                completionHandler?(.couldNotDeleteKey(folderUrl, error))
            }
        }
    }

    private func lock(key: String, andExecute block: @escaping (URL) -> Void) {
        DispatchQueue.main.async { [unowned self] in
            let folderUrl = self.baseUrl.appendingPathComponent(key, isDirectory: true)
            var semaphor = self.semaphorTable[key]
            var queue = self.queueTable[key]
            if semaphor == nil {
                semaphor = DispatchSemaphore(value: 1)
                queue = DispatchQueue(label: key)
                self.semaphorTable[key] = semaphor!
                self.queueTable[key] = queue!
                try?FileManager.default.createDirectory(at: folderUrl, withIntermediateDirectories: true, attributes: nil)
            }
            queue?.async {
                semaphor?.wait()
                block(folderUrl)
                semaphor?.signal()
            }
        }
    }
}

public final class DataArchiveLazyLockingReader {
    private let semaphor: DispatchSemaphore
    let folderUrl: URL
    let queue: DispatchQueue
    let numberOfArchives: Int
    private var currentArchiveIndex = -1
    private var finished = false

    fileprivate init(semaphor: DispatchSemaphore, folderUrl: URL, numberOfArchives: Int, queue: DispatchQueue = DispatchQueue.global()) {
        self.semaphor = semaphor
        self.folderUrl = folderUrl
        self.queue = DispatchQueue(label: "lazyReader")
        self.numberOfArchives = numberOfArchives
    }

    public func getNext(completionHandler: @escaping (Data?, DataArchiveResult) -> Void) {

        DispatchQueue.main.async { [unowned self] in
            guard self.finished == false else {
                completionHandler(nil, .lockingReaderWasFinished)
                return
            }
            if self.currentArchiveIndex == -1 {
                self.currentArchiveIndex = 0
            } else if self.currentArchiveIndex == 0 {
                self.currentArchiveIndex = self.numberOfArchives
            } else if self.currentArchiveIndex == 1 {
                self.finish()
                completionHandler(nil, .lockingReaderWasFinished)
                return
            } else {
                self.currentArchiveIndex -= 1
            }

            self.queue.async {
                let fileUrl = self.folderUrl.appendingPathComponent("\(self.currentArchiveIndex).dat")
                func tryReadFromTemp() {
                    let tempFile = self.folderUrl.appendingPathComponent("\(self.currentArchiveIndex).tmp")
                    do {
                        let data = try Data(contentsOf: tempFile)
                        completionHandler(data, .success)
                    } catch {
                        completionHandler(nil, .success)
                    }
                }
                do {
                    let data = try Data(contentsOf: fileUrl)
                    completionHandler(data, .success)
                } catch {
                    tryReadFromTemp()
                }
            }
        }
    }

    public func getNext<T: ValueConverter>(converterType: T.Type, completionHandler: @escaping (T.T?, DataArchiveResult) -> Void) {

        DispatchQueue.main.async { [unowned self] in
            guard self.finished == false else {
                completionHandler(nil, .lockingReaderWasFinished)
                return
            }
            if self.currentArchiveIndex == -1 {
                self.currentArchiveIndex = 0
            } else if self.currentArchiveIndex == 0 {
                self.currentArchiveIndex = self.numberOfArchives
            } else if self.currentArchiveIndex == 1 {
                self.finish()
                completionHandler(nil, .lockingReaderWasFinished)
                return
            } else {
                self.currentArchiveIndex -= 1
            }

            self.queue.async {
                let fileUrl = self.folderUrl.appendingPathComponent("\(self.currentArchiveIndex).dat")
                func tryReadFromTemp() {
                    let tempFile = self.folderUrl.appendingPathComponent("\(self.currentArchiveIndex).tmp")
                    do {
                        let data = try Data(contentsOf: tempFile)
                        if let fileContent = T.from(data: data)?.value {
                            completionHandler(fileContent, .success)
                        } else {
                            completionHandler(nil, .couldNotConvertFile(tempFile, "\(T.self)"))
                        }
                    } catch {
                        completionHandler(nil, .couldNotConvertFile(fileUrl, "\(T.self)"))
                    }
                }
                do {
                    let data = try Data(contentsOf: fileUrl)

                    if let fileContent = T.from(data: data)?.value {
                        completionHandler(fileContent, .success)
                    } else {
                        tryReadFromTemp()
                    }
                } catch {
                    tryReadFromTemp()
                }
            }
        }
    }

    public func finish() {
        DispatchQueue.main.async { [weak self] in
            guard self?.finished == false else { return }
            self?.finished = true
            self?.semaphor.signal()
        }
    }

    public var isFinished: Bool {
        return finished
    }

    deinit {
        if finished == false {
            semaphor.signal()
        }
    }
}

private struct DataValueConverter: ValueConverter {
    static func from(data: Data) -> DataValueConverter? {
        return DataValueConverter(value: data)
    }

    var toData: Data? {
        return value
    }

    let value: Data
}

public struct JSONValueConverter<T: Codable>: ValueConverter {
    public static func from(data: Data) -> JSONValueConverter<T>? {
        guard let value = try? JSONDecoder().decode(T.self, from: data) else {
            return nil
        }
        return JSONValueConverter(value: value)
    }

    public var toData: Data? {
        return try? JSONEncoder().encode(value)
    }

    public var value: T
    public init(value: T) {
        self.value = value
    }
}
