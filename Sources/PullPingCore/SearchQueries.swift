/// `involves` = author OR assignee OR mentions OR commenter; `review-requested` includes team requests;
/// `reviewed-by` covers reviews without comments.
public enum SearchQueries {
    public static let involved = "is:pr is:open archived:false involves:@me"
    public static let requested = "is:pr is:open archived:false review-requested:@me"
    public static let reviewed = "is:pr is:open archived:false reviewed-by:@me"
}
