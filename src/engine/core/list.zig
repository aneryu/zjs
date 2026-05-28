pub const Node = struct {
    prev: ?*Node = null,
    next: ?*Node = null,

    pub fn isLinked(self: Node) bool {
        return self.prev != null and self.next != null;
    }
};

pub const List = struct {
    head: Node = .{},

    pub fn init(self: *List) void {
        self.head.prev = &self.head;
        self.head.next = &self.head;
    }

    pub fn isEmpty(self: *const List) bool {
        return self.head.next == &self.head;
    }

    pub fn add(self: *List, node: *Node) void {
        insertBetween(node, &self.head, self.head.next.?);
    }

    pub fn addTail(self: *List, node: *Node) void {
        insertBetween(node, self.head.prev.?, &self.head);
    }

    pub fn remove(node: *Node) void {
        const prev = node.prev orelse return;
        const next = node.next orelse return;
        prev.next = next;
        next.prev = prev;
        node.prev = null;
        node.next = null;
    }

    fn insertBetween(node: *Node, prev: *Node, next: *Node) void {
        std.debug.assert(!node.isLinked());
        prev.next = node;
        node.prev = prev;
        node.next = next;
        next.prev = node;
    }
};

const std = @import("std");
