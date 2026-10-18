' ==============================================================================
' Warehouse Management System (WMS) - Data Access Module
' Status: Incomplete Conceptual Architectural Sketch (Illustrative Study)
' Author: Aryan Chintaman Manjhi (github.com/KiskuAryan)
'
' IMPORTANT ARCHITECTURAL DISCLAIMER:
' This file contains conceptual ADO.NET sketches demonstrating the difference
' between legacy single-threaded locking patterns and modern asynchronous,
' row-level patterns. It is an incomplete design study intended for architectural
' discussion and review, NOT a compiled or production-validated binary.
' Production deployment requires integration testing, concurrency benchmarks,
' and edge-case handling for warehouse-specific workflows.
' ==============================================================================

Imports System
Imports System.Data
Imports System.Data.SqlClient
Imports System.Threading.Tasks
Imports System.Collections.Generic

Namespace ConceptualWMS.DataAccess

    ''' <summary>
    ''' PART 1: LEGACY IMPLEMENTATION SKETCH (Identified Anti-Patterns)
    ''' Models the typical single-threaded ADO.NET patterns from legacy WMS backends.
    ''' </summary>
    Public Class LegacyOrderFulfillmentManager

        Private ReadOnly connectionString As String = "Server=wms-sql-srv01;Database=Enterprise_WMS;Integrated Security=True;"

        ''' <summary>
        ''' ANTI-PATTERN 1: The N+1 Network Roundtrip Problem
        ''' Issues 1 parent query followed by N sequential child queries inside a loop.
        ''' </summary>
        Public Function GetPendingOrdersLegacy() As DataTable
            Dim ordersTable As New DataTable()

            Using conn As New SqlConnection(connectionString)
                conn.Open()

                Dim orderSql As String = "SELECT * FROM orders WHERE status = 'PENDING' ORDER BY order_timestamp ASC"
                Using cmd As New SqlCommand(orderSql, conn)
                    Using adapter As New SqlDataAdapter(cmd)
                        adapter.Fill(ordersTable)
                    End Using
                End Using

                ' N+1 roundtrips across local network
                For Each row As DataRow In ordersTable.Rows
                    Dim orderId As Integer = Convert.ToInt32(row("order_id"))
                    Dim itemsSql As String = "SELECT * FROM order_items WHERE order_id = " & orderId.ToString()
                    Using itemCmd As New SqlCommand(itemsSql, conn)
                        Using itemAdapter As New SqlDataAdapter(itemCmd)
                            Dim itemsTable As New DataTable()
                            itemAdapter.Fill(itemsTable)
                        End Using
                    End Using
                Next
            End Using

            Return ordersTable
        End Function


        ''' <summary>
        ''' ANTI-PATTERN 2: Coarse-Grained Table Locking
        ''' Uses TABLOCKX which locks out concurrent barcode scan terminals across the warehouse.
        ''' </summary>
        Public Sub AllocateOrderBinsLegacy(ByVal orderId As Integer)
            Using conn As New SqlConnection(connectionString)
                conn.Open()
                Dim tx As SqlTransaction = conn.BeginTransaction(IsolationLevel.Serializable)

                Try
                    Dim allocSql As String = _
                        "UPDATE inventory_bins WITH (TABLOCKX) " & _
                        "SET current_qty = current_qty - oi.requested_qty " & _
                        "FROM inventory_bins b " & _
                        "INNER JOIN order_items oi ON b.current_sku_id = oi.sku_id " & _
                        "WHERE oi.order_id = @OrderId"

                    Using cmd As New SqlCommand(allocSql, conn, tx)
                        cmd.Parameters.AddWithValue("@OrderId", orderId)
                        cmd.ExecuteNonQuery()
                    End Using

                    Dim updateOrderSql As String = _
                        "UPDATE orders SET status = 'ALLOCATED' WHERE order_id = @OrderId"
                    Using cmdOrder As New SqlCommand(updateOrderSql, conn, tx)
                        cmdOrder.Parameters.AddWithValue("@OrderId", orderId)
                        cmdOrder.ExecuteNonQuery()
                    End Using

                    tx.Commit()
                Catch ex As Exception
                    tx.Rollback()
                    Throw
                End Try
            End Using
        End Sub

    End Class


    ''' <summary>
    ''' PART 2: PROPOSED ARCHITECTURAL SKETCH (Conceptual Modernization)
    ''' Demonstrates consistent batch selection, aggregated bin availability checking,
    ''' and non-blocking asynchronous execution.
    ''' </summary>
    Public Class ProposedOptimizedFulfillmentService

        Private ReadOnly _connectionString As String

        Public Sub New(connectionString As String)
            _connectionString = connectionString
        End Sub

        ''' <summary>
        ''' CONCEPTUAL FIX 1: Consistent Single-Roundtrip Batching
        ''' Uses a table variable to retrieve a consistent set of parent and child records
        ''' in one roundtrip. This is read-only selection; it does not reserve or claim orders,
        ''' so concurrent workers may select the same pending orders.
        ''' (Note: Production dispatch needs an explicit atomic claim/lease protocol.)
        ''' </summary>
        Public Async Function GetPendingOrdersBatchAsync(batchSize As Integer) As Task(Of DataSet)
            Dim ds As New DataSet("WmsPendingBatch")

            Const batchSql As String = 
                "SET NOCOUNT ON; " &
                "DECLARE @TargetOrders TABLE (order_id INT PRIMARY KEY); " &
                " " &
                "INSERT INTO @TargetOrders (order_id) " &
                "SELECT TOP (@BatchSize) order_id " &
                "FROM orders WITH (READCOMMITTEDLOCK) " &
                "WHERE status = 'PENDING' " &
                "ORDER BY CASE priority_level WHEN 'SAME_DAY' THEN 1 WHEN 'EXPRESS' THEN 2 ELSE 3 END, " &
                "         order_timestamp ASC; " &
                " " &
                "SELECT o.order_id, o.order_number, o.priority_level, o.order_timestamp " &
                "FROM orders o INNER JOIN @TargetOrders t ON o.order_id = t.order_id; " &
                " " &
                "SELECT oi.item_id, oi.order_id, oi.sku_id, oi.requested_qty, b.bin_id, b.bin_code " &
                "FROM order_items oi " &
                "INNER JOIN @TargetOrders t ON oi.order_id = t.order_id " &
                "INNER JOIN inventory_bins b ON oi.allocated_bin_id = b.bin_id;"

            Using conn As New SqlConnection(_connectionString)
                Using cmd As New SqlCommand(batchSql, conn)
                    cmd.Parameters.Add(New SqlParameter("@BatchSize", SqlDbType.Int) With {.Value = batchSize})
                    
                    Await conn.OpenAsync()
                    Using reader As SqlDataReader = Await cmd.ExecuteReaderAsync()
                        Dim ordersTable As DataTable = Await ReadResultAsync(reader, "Orders")
                        ds.Tables.Add(ordersTable)
                        If Await reader.NextResultAsync() Then
                            Dim itemsTable As DataTable = Await ReadResultAsync(reader, "OrderItems")
                            ds.Tables.Add(itemsTable)
                        End If
                    End Using
                End Using
            End Using

            Return ds
        End Function

        ''' <summary>
        ''' Materializes a result set while asynchronously reading rows from SQL Server.
        ''' </summary>
        Private Shared Async Function ReadResultAsync(reader As SqlDataReader, tableName As String) As Task(Of DataTable)
            Dim table As New DataTable(tableName)
            For columnIndex As Integer = 0 To reader.FieldCount - 1
                table.Columns.Add(reader.GetName(columnIndex), reader.GetFieldType(columnIndex))
            Next

            While Await reader.ReadAsync()
                Dim values(reader.FieldCount - 1) As Object
                reader.GetValues(values)
                table.Rows.Add(values)
            End While
            Return table
        End Function


        ''' <summary>
        ''' CONCEPTUAL FIX 2: Aggregated Bin Availability & Atomic Allocation
        ''' Revised logic addresses:
        ''' 1. Verifies order is PENDING prior to allocation.
        ''' 2. Aggregates demand per bin to prevent duplicate line items exceeding available stock.
        ''' 3. Uses ROWLOCK, UPDLOCK on bins to eliminate whole-table freezing on worker RF scanners.
        ''' (Note: Conceptual sketch. Production requires handling multi-warehouse transfers and serialized lots).
        ''' </summary>
        Public Async Function TryAllocateOrderAtomicAsync(orderId As Integer) As Task(Of Boolean)
            Const atomicSql As String =
                "SET NOCOUNT ON; SET XACT_ABORT ON; " &
                "DECLARE @AllocationSuccess bit = 0; " &
                "DECLARE @BinDemand TABLE (bin_id int PRIMARY KEY, total_demanded_qty int NOT NULL); " &
                "BEGIN TRY " &
                "  BEGIN TRANSACTION; " &
                "  IF EXISTS (SELECT 1 FROM orders WITH (UPDLOCK, HOLDLOCK) WHERE order_id = @OrderId AND status = 'PENDING') " &
                "     AND EXISTS (SELECT 1 FROM order_items WHERE order_id = @OrderId) " &
                "     AND NOT EXISTS (SELECT 1 FROM order_items WHERE order_id = @OrderId AND allocated_bin_id IS NULL) " &
                "  BEGIN " &
                "    INSERT INTO @BinDemand (bin_id, total_demanded_qty) " &
                "    SELECT allocated_bin_id, SUM(requested_qty) FROM order_items " &
                "    WHERE order_id = @OrderId GROUP BY allocated_bin_id; " &
                "    DECLARE @AvailableBins int; " &
                "    SELECT @AvailableBins = COUNT(*) FROM @BinDemand d " &
                "    INNER JOIN inventory_bins b WITH (UPDLOCK, HOLDLOCK, ROWLOCK) ON b.bin_id = d.bin_id " &
                "    WHERE b.current_qty >= d.total_demanded_qty; " &
                "    IF @AvailableBins = (SELECT COUNT(*) FROM @BinDemand) " &
                "    BEGIN " &
                "      UPDATE b SET current_qty = b.current_qty - d.total_demanded_qty " &
                "      FROM inventory_bins b INNER JOIN @BinDemand d ON d.bin_id = b.bin_id; " &
                "      UPDATE orders SET status = 'ALLOCATED' WHERE order_id = @OrderId AND status = 'PENDING'; " &
                "      IF @@ROWCOUNT = 1 SET @AllocationSuccess = 1; " &
                "    END; " &
                "  END; " &
                "  COMMIT TRANSACTION; " &
                "  SELECT @AllocationSuccess AS AllocationSuccess; " &
                "END TRY " &
                "BEGIN CATCH " &
                "  IF XACT_STATE() <> 0 ROLLBACK TRANSACTION; " &
                "  THROW; " &
                "END CATCH;"

            Using conn As New SqlConnection(_connectionString)
                Using cmd As New SqlCommand(atomicSql, conn)
                    cmd.Parameters.Add(New SqlParameter("@OrderId", SqlDbType.Int) With {.Value = orderId})
                    Await conn.OpenAsync()
                    Dim result As Object = Await cmd.ExecuteScalarAsync()
                    Return Convert.ToInt32(result) = 1
                End Using
            End Using
        End Function

    End Class

End Namespace
