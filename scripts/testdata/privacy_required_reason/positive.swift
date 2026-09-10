import Foundation

let defaults = UserDefaults.standard
let creation = URLResourceKey.creationDate
let modification = URLResourceKey.modificationDate
let fileModificationDate = FileAttributeKey.modificationDate
let contentModification = URLResourceKey.contentModificationDateKey
let creationKey = URLResourceKey.creationDateKey
_ = getattrlist(nil, nil, nil, 0, 0)
_ = getattrlistbulk(0, nil, nil, 0, nil)
_ = fgetattrlist(0, nil, nil, 0, 0)
_ = stat("/tmp/example", nil)
_ = fstat(0, nil)
_ = ProcessInfo.processInfo.systemUptime
_ = mach_absolute_time()
let available = URLResourceKey.volumeAvailableCapacityKey
let important = URLResourceKey.volumeAvailableCapacityForImportantUsageKey
let opportunistic = URLResourceKey.volumeAvailableCapacityForOpportunisticUsageKey
let total = URLResourceKey.volumeTotalCapacityKey
let free = systemFreeSize
let size = systemSize
_ = statfs("/tmp/example", nil)
_ = statvfs("/tmp/example", nil)
_ = fstatfs(0, nil)
_ = fstatvfs(0, nil)
_ = getattrlistat(0, nil, nil, 0, 0)
let keyboards = UITextInputMode.activeInputModes

_ = [defaults, creation, modification, fileModificationDate, contentModification,
     creationKey, available, important, opportunistic, total, free, size, keyboards]
