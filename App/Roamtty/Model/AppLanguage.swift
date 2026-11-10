/// The app's language, which picks the Chinese or the English wording. Helpers that only word things take this
/// instead of the whole model.
struct AppLanguage: Equatable {
    let english: Bool
    func text(_ chinese: String, _ english: String) -> String { self.english ? english : chinese }
}
