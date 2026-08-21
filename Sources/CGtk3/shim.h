#ifndef METERUSAGE_CGTK3_SHIM_H
#define METERUSAGE_CGTK3_SHIM_H

#include <gtk/gtk.h>

typedef void (*MeterUsageGtkActivateCallback)(GtkMenuItem *, gpointer);

static inline gulong meterusage_gtk_connect_activate(
    GtkWidget *item,
    MeterUsageGtkActivateCallback callback,
    gpointer data
) {
    return g_signal_connect(item, "activate", G_CALLBACK(callback), data);
}

static inline void meterusage_gtk_menu_append(GtkWidget *menu, GtkWidget *item) {
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
}

static inline void meterusage_gtk_menu_clear(GtkWidget *menu) {
    GList *children = gtk_container_get_children(GTK_CONTAINER(menu));
    for (GList *node = children; node != NULL; node = node->next) {
        gtk_widget_destroy(GTK_WIDGET(node->data));
    }
    g_list_free(children);
}

#endif
