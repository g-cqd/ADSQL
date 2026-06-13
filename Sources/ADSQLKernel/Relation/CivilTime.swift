import Darwin

/// `datetime('now')` defaults without Foundation: UTC wall clock formatted
/// as SQLite does ("YYYY-MM-DD HH:MM:SS"). Civil-date math is the classic
/// days-from-civil/civil-from-days algorithm (Howard Hinnant).
public enum CivilTime {
  public static func utcNowString() -> String {
    var ts = timespec()
    unsafe clock_gettime(CLOCK_REALTIME, &ts)
    return string(forEpochSeconds: Int64(ts.tv_sec))
  }

  public static func string(forEpochSeconds seconds: Int64) -> String {
    let days = floorDivide(seconds, 86_400)
    var secondsOfDay = seconds - days * 86_400
    if secondsOfDay < 0 { secondsOfDay += 86_400 }
    let (year, month, day) = civilFromDays(days)
    let hour = secondsOfDay / 3600
    let minute = (secondsOfDay % 3600) / 60
    let second = secondsOfDay % 60
    return pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2)
      + " " + pad(hour, 2) + ":" + pad(minute, 2) + ":" + pad(second, 2)
  }

  private static func civilFromDays(_ z0: Int64) -> (year: Int64, month: Int64, day: Int64) {
    let z = z0 + 719_468
    let era = floorDivide(z, 146_097)
    let dayOfEra = z - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    var year = yearOfEra + era * 400
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let mp = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * mp + 2) / 5 + 1
    let month = mp < 10 ? mp + 3 : mp - 9
    if month <= 2 { year += 1 }
    return (year, month, day)
  }

  @inline(__always)
  private static func floorDivide(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b
    return (a % b != 0 && (a ^ b) < 0) ? q - 1 : q
  }

  private static func pad(_ value: Int64, _ width: Int) -> String {
    let s = String(value)
    return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
  }
}
