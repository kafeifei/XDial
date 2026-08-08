enum ScenarioGridLayout {
    /// 保持每行不超过上限，并在不可避免的最少行数内尽量均分列数。
    static func columnCount(itemCount: Int, maximumPerRow: Int = 4) -> Int {
        guard itemCount > 0, maximumPerRow > 0 else { return 1 }
        let minimumRows = (itemCount + maximumPerRow - 1) / maximumPerRow
        return min(
            maximumPerRow,
            (itemCount + minimumRows - 1) / minimumRows
        )
    }
}
