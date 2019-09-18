# DataArchive 
[![Build Status](https://travis-ci.org/mzaks/DataArchive.svg?branch=master)](https://travis-ci.org/mzaks/DataArchive)

> An archive is a collection of data moved to a repository for backup, to keep separate for compliance reasons.
> - https://searchstorage.techtarget.com/definition/archive

`DataArchive` is a small library, which abstracts away the complexity of file I/O in a multi threaded scenario, making it easy for developers to store `Data` instances by __"key"__. Similar to `UserDefaults`, but with no size limit and no in memory caching. `DataArchive` also lets users store multiple _versions_ of the same _document_.

# Storing the data

Consider following code:

```
DataArchive.default.set(key:"myData", data: data)
```

In this code we are using the `default` instance of `DataArchive` to store a `data` instance by key `"myData"`.
The `default` DataArchive instance is using the `Library` folder of your user space to create a `data_archive` folder and than a sub folder for every __key__ the user provides. The data itself will be stored as a `0.dat` file inside of the __key__ named subfolder.

If you want to put your file in a different folder (e.g. `Documents` folder), you can instantiate your own `DataArchive` object with provided root `URL`.

Internally `DataArchive` creates a serial queue for every __key__, performing the expensive file I/O operations on this queue. It you are interested in the result of the operation, please provide `completionHandler`:

```
DataArchive.default.set(key:"myData", data: data) { result in
	print(result)
}
```

`result` is an instance of `DataArchiveResult` enum, wich has a `success` case and different error cases carrying necessary information to identify the root cause of the problem.

---

When we call `set(key:, data:)` method and there is already a `0.dat` file present in the __key__ based subfolder. The `0.dat` file is renamed to `0.tmp` file, the new data is stored in `0.dat` file and the `0.tmp` file is deleted. This technique is intended to keep the old value as long as we are not certain the new value is stored successfully. If there will be a crash during the creation of the new `0.dat` file. We still have the `0.tmp` file which `DataArchive` can recover.

---

As mentioned before, `DataArchive` lets users store multiple _versions_ of the same _document_. This can be achieved by calling following method:

```
DataArchive.default.archiveCurrent(key: key, andSetNewData: data)
```

In this case if we already have `0.dat` file in the __key__ based subfolder, we will rename it to `1.dat`, or rather `#.dat` (where `#` is the next available version number) and store the `data` instance in `0.dat` file. If the `0.dat` file is not present yet, we will just store the data instance in `0.dat` file.

# Reading the data

In order to read the last stored data instance for a given key, we can use following method:

```
DataArchive.default.get(key: key) { (data, result) in
	guard result.isSuccess else {
		print(result)
		return
	}
    // Do something with data
}
```

This method reads the content of the `0.dat` file and returns it to us in `completionHandler`. As I mentioned before, `DataArchive` keeps a dedicated serial queue for every key. This makes sure that working with different keys can be done in parallel, but working with values in the same key is serialised and deterministic.

Meaning than if you call `set(key:data:)` and than `get(key:completionHandler)` the `completionHandler` of the `get` call will be executed after `set` operation is finished. This way we call `set` methods in a _fire and forget_ fashion and can avoid the callback heel and pyramid of doom.

---

If we want to get all the versions of the documents stored under given __key__, we have two options.

### Eager read of all versions
```
DataArchive.default.getAll(key: key) { (dataArray, result) in
    guard result.isSuccess else {
		print(result)
		return
	}
	// Do something with data array
}
```

With `getAll(key:completionHandler)` method call, we get all data instances which are stored in the __key__ based folder started with most recent document and endign with the oldest one.

This however means that we will read and instantiate many data instances at once, whch could be time and memory consuming. This is why we have another option.

### Lazy and locking read of all versions

```
var reader: DataArchiveLazyLockingReader?
DataArchive.default.lazyLockingReader(key: key) { (_reader) in
    reader = _reader
}
```

We can ask `DataArchive` to provide us a lazy locking reader for a given __key__, which we can use to iterater over the documents at our convinience. There is however one very important side effect. When an instance of `DataArchiveLazyLockingReader` is created, it locks the __key__ based serial queue from scheduling blocks (it will still be able to receive and stroe new blocks though). We do it because we want to make sure, that the document versions stay stable untill we are done iterating over them. When the oldest document is read by `DataArchiveLazyLockingReader` it will automatically unlock the queue. We can also unlock the queue explicitly by calling the `finish()` method on `DataArchiveLazyLockingReader` instance.

# Delete the data

We have two options how we can delete data in `DataArchive`.

### Delete all data and versions for key

```
DataArchive.default.delete(key: key)
```

This method call is scheduled on the (__key__ based) dedicated serial queue and deletes the whole __key__ based subfolder. Which is what we want to do in 90% of the cases. However if we have multiple versions of document, we might want to cleanup the old versions only. In this case, following option can be used.

### Delete old versions for key

```
DataArchive.default.keep(upTo: 5, archivesForKey: key)
```

With this call we are telling the `DataArchive` to keep the current version and up to `X` youngest versions of the document.

# Storing instances of objects which can be converted to `Data`

In the first paragraph we describe `DataArchive` as a library, which makes it easy for developers to store `Data` instances. This is usefull by itself, but in the day to day work, we are dealing with values, which are not instances of `Data`, but rather can be converted to one. For example `UIImage`, or classes / structs complying to `Codable` protocol.

`DataArchive` provides a `ValueConverter` protocol which can be used store and read data, as an alternative.

The library provides one implementation of the `ValueConverter` protocol in order to read and store `Codable` confirming values:

```
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
```

Given `JSONValueConverter` and a `Person` class:

```
class Person: Codable {
    let name: String
    let age: Int
    init(name: String, age: Int) {
        self.name = name
        self.age = age
    }
}
```

We can store a person instance:
```
let person = Person(name: "Maxim", age: 38)
let value = JSONValueConverter(value: person)
var result: DataArchiveResult?
DataArchive.default.set(key: "person", value: value)
```

And read the stored value as following: 
```
self.archive.get(
	key: "person", 
	converterType: JSONValueConverter<Person>.self
) { (person, result) in
    guard result.isSuccess else {
		print(result)
		return
	}
	// Do something with person
}
```

The good thing about this mechanism, the conversion of the value to `Data` instance (which can be very computantionaly expensive) is happening on __key__ based queue. Making us worry less about congesting the main thread.
