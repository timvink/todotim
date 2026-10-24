import Foundation

/// Fixtures in the shape of Todoist API v1 responses (field sets copied from the samples at
/// https://developer.todoist.com/api/v1/, values made up).
enum TodoistFixtures {
    /// GET /api/v1/projects, one page.
    static let projectsPage = """
    {
      "results": [
        {
          "id": "6Jf8VQXxpwv56VQ7", "can_assign_tasks": false, "can_comment": true, "child_order": 0,
          "order_key": "a0", "is_collapsed": false, "color": "charcoal", "icon": null,
          "creator_uid": "1234567", "created_at": "2023-03-01T09:00:00.000000Z", "is_archived": false,
          "is_deleted": false, "is_favorite": false, "is_frozen": false, "name": "Inbox", "is_shared": false,
          "updated_at": "2025-01-16T10:30:00Z", "view_style": "list", "default_order": 0,
          "description": "", "public_key": "", "access": null, "role": null, "parent_id": null,
          "inbox_project": true
        },
        {
          "id": "6XGgm6PHrGgMpCFX", "can_assign_tasks": true, "can_comment": true, "child_order": 2,
          "order_key": "a2", "is_collapsed": false, "color": "berry_red", "icon": "lightbulb",
          "creator_uid": "1234567", "created_at": "2025-01-15T10:30:00Z", "is_archived": false,
          "is_deleted": false, "is_favorite": true, "is_frozen": false, "name": "Work", "is_shared": false,
          "updated_at": "2025-01-16T10:30:00Z", "view_style": "list", "default_order": 1,
          "description": "Tasks for the launch plan", "public_key": "", "access": null, "role": "admin",
          "parent_id": null, "inbox_project": false
        },
        {
          "id": "6XGgmC7hQpRw3m2v", "child_order": 1, "order_key": "a1", "color": "lime_green",
          "is_archived": false, "is_deleted": false, "name": "Home", "parent_id": null, "inbox_project": false
        },
        {
          "id": "6XGgmJ4cWq9xFr8P", "child_order": 0, "order_key": "a0", "color": "sky_blue",
          "is_archived": false, "is_deleted": false, "name": "Launch", "parent_id": "6XGgm6PHrGgMpCFX",
          "inbox_project": false
        },
        {
          "id": "6XGgmMv2Rk7pHq4C", "child_order": 0, "order_key": "a0", "color": "not_a_color",
          "is_archived": false, "is_deleted": false, "name": "Press", "parent_id": "6XGgmJ4cWq9xFr8P",
          "inbox_project": false
        },
        {
          "id": "6XGgmQw8Jx2Lb5Tn", "child_order": 3, "order_key": "a3", "color": "grey",
          "is_archived": true, "is_deleted": false, "name": "Old stuff", "parent_id": null,
          "inbox_project": false
        }
      ],
      "next_cursor": null
    }
    """

    /// GET /api/v1/sections
    static let sectionsPage = """
    {
      "results": [
        {
          "id": "6fFPHV272WWh3gpW", "user_id": "1234567", "project_id": "6XGgm6PHrGgMpCFX",
          "added_at": "2025-01-15T10:30:00Z", "updated_at": "2025-01-16T10:30:00Z", "archived_at": null,
          "name": "Doing", "description": "", "section_order": 2, "order_key": "a2", "is_collapsed": false,
          "is_archived": false, "is_deleted": false
        },
        {
          "id": "6fFPHXm2v8PqT4kR", "project_id": "6XGgm6PHrGgMpCFX", "name": "Backlog",
          "section_order": 1, "order_key": "a1", "is_collapsed": false, "is_archived": false, "is_deleted": false
        },
        {
          "id": "6fFPHc9Rw3Jm7NvB", "project_id": "6Jf8VQXxpwv56VQ7", "name": "Someday",
          "section_order": 1, "order_key": "a1", "is_archived": false, "is_deleted": false
        },
        {
          "id": "6fFPHgT5Lp2Wx8Kd", "project_id": "6XGgm6PHrGgMpCFX", "name": "Archived",
          "section_order": 3, "order_key": "a3", "is_archived": true, "is_deleted": false
        }
      ],
      "next_cursor": null
    }
    """

    /// GET /api/v1/tasks
    static let tasksPage = """
    {
      "results": [
        {
          "user_id": "1234567", "id": "6XGgmFVcrG5RRjVr", "project_id": "6XGgm6PHrGgMpCFX",
          "section_id": "6fFPHV272WWh3gpW", "parent_id": null, "added_by_uid": "1234567",
          "assigned_by_uid": null, "responsible_uid": null, "labels": ["priority", "Errand"],
          "deadline": {"date": "2025-02-12", "lang": "en"}, "duration": {"amount": 30, "unit": "minute"},
          "is_collapsed": true, "checked": false, "is_deleted": false, "added_at": "2025-01-15T10:30:00.123456Z",
          "completed_at": null, "completed_by_uid": null, "updated_at": "2025-01-17T10:30:00Z",
          "due": {"date": "2025-02-12", "is_recurring": false, "lang": "en", "string": "Feb 12", "timezone": null},
          "priority": 4, "child_order": 2, "order_key": "a2", "content": "Write launch post",
          "description": "Draft in **Markdown**\\nwith two lines", "note_count": 0, "day_order": -1,
          "completed_count": 0, "postponed_count": 1
        },
        {
          "id": "6XGgmH3vKq8Jt2Wc", "project_id": "6XGgm6PHrGgMpCFX", "section_id": "6fFPHV272WWh3gpW",
          "parent_id": null, "labels": [], "checked": false, "is_deleted": false,
          "added_at": "2025-01-15T11:00:00Z", "due": {"date": "2025-03-01T09:30:00Z", "is_recurring": true,
          "string": "every month at 9:30", "lang": "en", "timezone": "Europe/Amsterdam"},
          "priority": 3, "child_order": 1, "order_key": "a1", "content": "Monthly report", "description": ""
        },
        {
          "id": "6XGgmK7nPr4Lw9Xd", "project_id": "6XGgm6PHrGgMpCFX", "section_id": "6fFPHV272WWh3gpW",
          "parent_id": "6XGgmFVcrG5RRjVr", "labels": ["priority"], "checked": false, "is_deleted": false,
          "added_at": "2025-01-16T08:00:00Z", "due": null, "priority": 2, "child_order": 2,
          "content": "Get screenshots", "description": ""
        },
        {
          "id": "6XGgmM2xQs6Ny3Ve", "project_id": "6XGgm6PHrGgMpCFX", "section_id": "6fFPHV272WWh3gpW",
          "parent_id": "6XGgmFVcrG5RRjVr", "labels": [], "checked": false, "is_deleted": false,
          "priority": 1, "child_order": 1, "content": "Outline", "description": ""
        },
        {
          "id": "6XGgmP5zTu8Pa4Wf", "project_id": "6XGgm6PHrGgMpCFX", "section_id": null, "parent_id": null,
          "labels": [], "checked": true, "is_deleted": false, "completed_at": "2025-01-20T12:00:00Z",
          "priority": 1, "child_order": 1, "content": "Done already", "description": ""
        },
        {
          "id": "6XGgmR8bVw2Rc5Xg", "project_id": "6XGgm6PHrGgMpCFX", "section_id": "6fFPHgT5Lp2Wx8Kd",
          "parent_id": null, "labels": [], "checked": false, "is_deleted": false,
          "priority": 1, "child_order": 1, "content": "In archived section", "description": ""
        },
        {
          "id": "6XGgmT3dXy5Td6Yh", "project_id": "6Jf8VQXxpwv56VQ7", "section_id": null, "parent_id": null,
          "labels": ["shared-label"], "checked": false, "is_deleted": false,
          "priority": 1, "child_order": 1, "content": "Buy milk", "description": "Pick up organic milk"
        },
        {
          "id": "6XGgmV6fZa8Uf7Zi", "project_id": "6Jf8VQXxpwv56VQ7", "section_id": "6fFPHc9Rw3Jm7NvB",
          "parent_id": null, "labels": [], "checked": false, "is_deleted": false,
          "priority": 1, "child_order": 1, "content": "Learn Swift macros", "description": ""
        },
        {
          "id": "6XGgmX9hBc2Vg8Aj", "project_id": "6XGgmQw8Jx2Lb5Tn", "section_id": null, "parent_id": null,
          "labels": [], "checked": false, "is_deleted": false,
          "priority": 1, "child_order": 1, "content": "In archived project", "description": ""
        },
        {
          "id": "6XGgmZ2kDe5Wh9Bk", "project_id": "6XGgmMv2Rk7pHq4C", "section_id": null, "parent_id": null,
          "labels": [], "checked": false, "is_deleted": false, "due": {"date": "2025-04-01"},
          "priority": 1, "child_order": 1, "content": "Send press kit", "description": ""
        }
      ],
      "next_cursor": null
    }
    """

    /// GET /api/v1/labels
    static let labelsPage = """
    {
      "results": [
        {"id": "2147509004", "name": "Priority", "color": "berry_red", "order": 12, "is_favorite": false},
        {"id": "2147509005", "name": "errand", "color": "teal", "order": 3, "is_favorite": false}
      ],
      "next_cursor": null
    }
    """

    /// The four pages above as one snapshot file.
    static var snapshotJSON: String {
        func results(_ page: String) -> String {
            let obj = try! JSONSerialization.jsonObject(with: Data(page.utf8)) as! [String: Any]
            let data = try! JSONSerialization.data(withJSONObject: obj["results"]!)
            return String(decoding: data, as: UTF8.self)
        }
        return """
        {"projects": \(results(projectsPage)), "sections": \(results(sectionsPage)),
         "tasks": \(results(tasksPage)), "labels": \(results(labelsPage))}
        """
    }
}
