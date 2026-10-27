// Independent full literal for the fixed core namespace detail query. Update
// this fixture and its core assertion together when the document changes.
const namespaceWorkItemQuery = r'''
query MobileNamespaceWorkItem($path: ID!, $iid: String!) {
  namespace(fullPath: $path) {
    id
    fullPath
    workItem(iid: $iid) { id
iid
title
state
createdAt
updatedAt
project { id fullPath }
namespace { id fullPath }
workItemType { id name }

description
widgets {
  type
  ... on WorkItemWidgetDescription {
    description
    edited
    lastEditedAt
  }
  ... on WorkItemWidgetAssignees {
    assignees(first: 20) {
      nodes { id name username }
      pageInfo { hasNextPage endCursor }
    }
  }
  ... on WorkItemWidgetLabels {
    labels(first: 50) {
      nodes { id title color description textColor }
      pageInfo { hasNextPage endCursor }
    }
  }
  ... on WorkItemWidgetHierarchy {
    hasParent
    hasChildren
    parent { id
iid
title
state
createdAt
updatedAt
project { id fullPath }
namespace { id fullPath }
workItemType { id name }
 }
    children(first: 20) {
      nodes { id
iid
title
state
createdAt
updatedAt
project { id fullPath }
namespace { id fullPath }
workItemType { id name }
 }
      pageInfo { hasNextPage endCursor }
    }
  }
  ... on WorkItemWidgetStartAndDueDate {
    startDate
    dueDate
    rollUp
  }
}
 }
  }
}
''';
