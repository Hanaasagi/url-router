pub const InsertError = error{
    /// Attempted to insert a path that conflicts with an existing route.
    Conflict,
    /// Only one parameter per route segment is allowed.
    TooManyParams,
    /// Parameters must be registered with a name.
    UnnamedParam,
    /// Catch-all parameters are only allowed at the end of a path.
    InvalidCatchAll,
};

pub const MatchError = error{
    /// The path was missing a trailing slash.
    MissingTrailingSlash,
    /// The path had an extra trailing slash.
    ExtraTrailingSlash,
    /// No matching route was found.
    NotFound,
};
